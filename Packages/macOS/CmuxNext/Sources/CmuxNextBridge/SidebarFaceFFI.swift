import CCmuxLayoutReducerFFI
import CmuxNextDaemon
import Foundation

/// Thin FFI call to cmux-layout-reducer's sidebar row face rules (`cmux_sidebar_face_*`): it encodes one
/// workspace's tabs (O(its tabs)) into the C request, makes one call and copies the flat reply out. It decides
/// nothing. Its one state is the Rust handle, which owns the reply buffers and reuses them on every call: so it is
/// used on the main actor only, and each reply is copied out before the next call.
@MainActor
final class SidebarFaceFFI {
    static let shared = SidebarFaceFFI()
    static let none = UInt32.max
    /// The face handle's address (0: none), a plain value, so the nonisolated deinit can free it. Used on the main
    /// actor only; the deinit runs when nothing else can.
    private let handleAddress = UInt(bitPattern: cmux_sidebar_face_new())
    private var handle: OpaquePointer? { OpaquePointer(bitPattern: handleAddress) }
    private let home: [UInt8]

    init(home: String = NSHomeDirectory()) { self.home = Array(home.utf8) }

    nonisolated deinit { cmux_sidebar_face_free(OpaquePointer(bitPattern: handleAddress)) }

    /// What a call encodes, so it reads (and its caller observes) only what its rule needs: `front` the panes
    /// (focus, selection), `work` also each tab's kind and chat, page and app marks, `face` also each tab's title,
    /// folder, agent state, command and New Tab page (the label and chat rules), `row` every field.
    enum Level: Int { case front, work, face, row }

    /// One row's face as the reply gave it: `row`'s tab fields index the workspace's tabs in pane order.
    struct Face {
        var row = Face.noRow
        var listed: [CmuxSidebarFaceListedTab] = []
        var kept: [UInt32] = []
        var strings: [UInt8] = []

        /// A row with no tab, no text and no marks (a request the rules could not read).
        static let noRow: CmuxSidebarFaceRow = {
            var row = CmuxSidebarFaceRow()
            let absent = CmuxSidebarFaceRange(offset: SidebarFaceFFI.none, len: 0)
            (row.front, row.label, row.face, row.work, row.chat) = (SidebarFaceFFI.none, SidebarFaceFFI.none, SidebarFaceFFI.none, SidebarFaceFFI.none, SidebarFaceFFI.none)
            (row.folder_tab, row.bucket_tab, row.agent, row.notice_tab) = (SidebarFaceFFI.none, SidebarFaceFFI.none, SidebarFaceFFI.none, SidebarFaceFFI.none)
            (row.ports, row.pull_request) = (SidebarFaceFFI.none, SidebarFaceFFI.none)
            (row.directory, row.bucket, row.process, row.status_line) = (absent, absent, absent, absent)
            return row
        }()

        func index(_ value: UInt32) -> Int? { value == SidebarFaceFFI.none ? nil : Int(value) }

        func text(_ range: CmuxSidebarFaceRange) -> String? {
            let start = Int(range.offset), end = start + Int(range.len)
            guard range.offset != SidebarFaceFFI.none, end <= strings.count else { return nil }
            return String(decoding: strings[start ..< end], as: UTF8.self)
        }

        /// The listed tab of tab `tab`.
        func listed(_ tab: Int) -> CmuxSidebarFaceListedTab? {
            let index = Int(row.listed_start) + tab
            return listed.indices.contains(index) ? listed[index] : nil
        }

        /// The entry indexes the status block lists.
        var keptEntries: [Int] {
            let start = Int(row.kept_entry_start), end = start + Int(row.kept_entry_count)
            return end <= kept.count ? kept[start ..< end].map { Int($0) } : []
        }
    }

    // swiftlint:disable:next function_parameter_count
    func face(_ workspace: WorkspaceModel, level: Level = .row, local: Bool, status: String?, showsUnread: Bool,
              newTabPages: Set<String>, newTabTitled: Bool, listTitles: [String], selectedTab: (PaneModel) -> String?,
              branded: (TabModel) -> Bool) -> Face? {
        var strings = home
        func add(_ text: String?) -> CmuxSidebarFaceRange {
            guard let text else { return CmuxSidebarFaceRange(offset: Self.none, len: 0) }
            let offset = strings.count
            strings.append(contentsOf: text.utf8)
            return CmuxSidebarFaceRange(offset: UInt32(clamping: offset), len: UInt32(clamping: strings.count - offset))
        }
        var panes: [CmuxSidebarFacePane] = [], tabs: [CmuxSidebarFaceTab] = [], entries: [CmuxSidebarFaceEntry] = []
        for pane in workspace.screens.flatMap(\.panes) {
            let selected = selectedTab(pane).flatMap { id in pane.tabs.firstIndex { $0.id == id } }
            panes.append(CmuxSidebarFacePane(focused_at: pane.focusedAt, default_tab: Int64(pane.defaultTabIndex),
                                             tab_count: UInt32(clamping: pane.tabs.count),
                                             selected: selected.map { UInt32(clamping: $0) } ?? Self.none))
            for tab in pane.tabs {
                let absent = CmuxSidebarFaceRange(offset: Self.none, len: 0)
                var row = CmuxSidebarFaceTab()
                (row.title, row.list_title, row.cwd, row.progress_value) = (absent, absent, absent, .min)
                // The header's CMUX_SIDEBAR_FACE_TAB_* bits.
                var flags: UInt32 = 0
                func mark(_ on: Bool, _ bit: UInt32) { if on { flags |= bit } }
                if level.rawValue >= Level.work.rawValue {
                    row.kind = switch tab.kind { case .pty: 0; case .browser: 1; case .remoteTerminal: 2; case .conversation: 3; case .other: 4 }
                    mark(tab.agentSession != nil, 2); mark(tab.page != nil, 16); mark(tab.appTab != nil, 32)
                }
                if level.rawValue >= Level.face.rawValue {
                    (row.title, row.cwd) = (add(tab.titleText), add(tab.cwd))
                    row.agent = switch tab.agent?.state { case nil: 0; case .working?: 1; case .blocked?: 2; case _?: 3 }
                    mark(tab.commandSinceMs != nil, 4); mark(tab.titleActivity != nil, 8); mark(newTabPages.contains(tab.id), 64)
                }
                if level == .row {
                    row.list_title = add(listTitles.indices.contains(tabs.count) ? listTitles[tabs.count] : tab.displayTitle)
                    mark(!(tab.name ?? "").isEmpty, 1); mark(branded(tab), 128); mark(tab.hasUnread, 256)
                    mark(tab.markedUnread, 512); mark(tab.attention != nil, 1024)
                    row.progress_state = switch tab.progress?.state { case nil: 0; case .normal?: 1; case .error?: 2; case .indeterminate?: 3; case .paused?: 4 }
                    // A negative report reaches the app's clamp as 0 (never the no-value marker, Int32.min).
                    row.progress_value = tab.progress?.value.map { Int32(clamping: max($0, 0)) } ?? .min
                    row.notification = tab.notification?.notification.rawValue ?? 0
                    row.attention_at_ms = tab.attention?.atMs ?? 0
                    row.agent_updated_ms = tab.agent?.updatedAtMs ?? 0
                    row.notification_created_ms = tab.notification?.createdAtMs ?? 0
                }
                row.flags = flags
                tabs.append(row)
            }
        }
        var row = CmuxSidebarFaceWorkspace()
        row.flags = local ? 1 : 0
        row.status = CmuxSidebarFaceRange(offset: Self.none, len: 0)
        if level == .row {
            for entry in workspace.status?.entries ?? [] {
                let key = add(entry.key), text = add(entry.text)
                entries.append(CmuxSidebarFaceEntry(key: key, text: text))
            }
            row.flags |= (workspace.markedUnread ? 2 : 0) | (workspace.status?.progress != nil ? 4 : 0)
            row.reported_progress = workspace.status?.progress.map { $0.value ?? .nan } ?? 0
            row.unread_count = UInt64(clamping: workspace.unreadCount)
            row.status = add(status)
        }
        (row.pane_count, row.tab_count, row.entry_count) = (UInt32(clamping: panes.count), UInt32(clamping: tabs.count), UInt32(clamping: entries.count))
        let homeRange = CmuxSidebarFaceRange(offset: 0, len: UInt32(clamping: home.count))
        return withUnsafePointer(to: row) { workspaces in
            panes.withUnsafeBufferPointer { panes in
                tabs.withUnsafeBufferPointer { tabs in
                    entries.withUnsafeBufferPointer { entries in
                        strings.withUnsafeBufferPointer { bytes in
                            var request = CmuxSidebarFaceRequest(
                                workspaces: workspaces, panes: panes.baseAddress, tabs: tabs.baseAddress, entries: entries.baseAddress,
                                workspace_count: 1, pane_count: row.pane_count, tab_count: row.tab_count, entry_count: row.entry_count,
                                home: homeRange, shows_unread: showsUnread ? 1 : 0, new_tab_titled: newTabTitled ? 1 : 0, reserved: (0, 0, 0, 0, 0, 0))
                            return Self.copy(cmux_sidebar_face_rows(handle, &request, bytes.baseAddress, bytes.count))
                        }
                    }
                }
            }
        }
    }

    /// The reply's one face and its buffers, copied before the next call can replace them.
    private static func copy(_ reply: UnsafePointer<CmuxSidebarFaceReply>?) -> Face? {
        guard let reply = reply?.pointee, reply.ok != 0, reply.face_count == 1, let row = reply.faces?.pointee else { return nil }
        return Face(row: row, listed: Array(UnsafeBufferPointer(start: reply.listed, count: Int(reply.listed_count))),
                    kept: Array(UnsafeBufferPointer(start: reply.kept_entries, count: Int(reply.kept_entry_count))),
                    strings: Array(UnsafeBufferPointer(start: reply.strings, count: Int(reply.strings_len))))
    }

    /// The daemon's next default workspace name: `existing` listed names, then `reserved` ones.
    func defaultWorkspaceName(existing: [String], reserved: [String]) -> String? {
        var strings: [UInt8] = [], names: [CmuxSidebarFaceRange] = []
        for name in existing + reserved {
            names.append(CmuxSidebarFaceRange(offset: UInt32(clamping: strings.count), len: UInt32(clamping: name.utf8.count)))
            strings.append(contentsOf: name.utf8)
        }
        return names.withUnsafeBufferPointer { names in
            strings.withUnsafeBufferPointer { bytes in
                Self.string(cmux_sidebar_face_default_name(handle, names.baseAddress, UInt32(clamping: names.count),
                                                           UInt32(clamping: existing.count), bytes.baseAddress, bytes.count))
            }
        }
    }

    private static func string(_ reply: UnsafePointer<CmuxSidebarFaceText>?) -> String? {
        guard let text = reply?.pointee, text.ok != 0 else { return nil }
        return String(decoding: UnsafeBufferPointer(start: text.bytes, count: Int(text.len)), as: UTF8.self)
    }
}
