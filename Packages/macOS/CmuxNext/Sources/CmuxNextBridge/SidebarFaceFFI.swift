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

    /// One row's face as the reply gave it: `row`'s tab fields index the workspace's tabs in pane order.
    struct Face {
        var row = CmuxSidebarFaceRow()
        var listed: [CmuxSidebarFaceListedTab] = []
        var kept: [UInt32] = []
        var strings: [UInt8] = []

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
    func face(_ workspace: WorkspaceModel, local: Bool, status: String?, showsUnread: Bool, newTabPages: Set<String>,
              newTabTitled: Bool, listTitles: [String], selectedTab: (PaneModel) -> String?,
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
                // The header's CMUX_SIDEBAR_FACE_TAB_* bits, in order.
                let bits = [!(tab.name ?? "").isEmpty, tab.agentSession != nil, tab.commandSinceMs != nil, tab.titleActivity != nil,
                            tab.page != nil, tab.appTab != nil, newTabPages.contains(tab.id), branded(tab), tab.hasUnread,
                            tab.markedUnread, tab.attention != nil]
                var row = CmuxSidebarFaceTab()
                row.title = add(tab.titleText)
                row.list_title = add(listTitles.indices.contains(tabs.count) ? listTitles[tabs.count] : tab.displayTitle)
                row.cwd = add(tab.cwd)
                row.flags = bits.enumerated().reduce(0) { $1.element ? $0 | 1 << UInt32($1.offset) : $0 }
                row.kind = switch tab.kind { case .pty: 0; case .browser: 1; case .remoteTerminal: 2; case .conversation: 3; case .other: 4 }
                row.agent = switch tab.agent?.state { case nil: 0; case .working?: 1; case .blocked?: 2; case _?: 3 }
                row.progress_state = switch tab.progress?.state { case nil: 0; case .normal?: 1; case .error?: 2; case .indeterminate?: 3; case .paused?: 4 }
                row.progress_value = tab.progress?.value.map { Int32(clamping: $0) } ?? .min
                row.notification = tab.notification?.notification.rawValue ?? 0
                row.attention_at_ms = tab.attention?.atMs ?? 0
                row.agent_updated_ms = tab.agent?.updatedAtMs ?? 0
                row.notification_created_ms = tab.notification?.createdAtMs ?? 0
                tabs.append(row)
            }
        }
        for entry in workspace.status?.entries ?? [] {
            let key = add(entry.key), text = add(entry.text)
            entries.append(CmuxSidebarFaceEntry(key: key, text: text))
        }
        var row = CmuxSidebarFaceWorkspace()
        (row.pane_count, row.tab_count, row.entry_count) = (UInt32(clamping: panes.count), UInt32(clamping: tabs.count), UInt32(clamping: entries.count))
        row.flags = (local ? 1 : 0) | (workspace.markedUnread ? 2 : 0) | (workspace.status?.progress != nil ? 4 : 0)
        row.reported_progress = workspace.status?.progress.map { $0.value ?? .nan } ?? 0
        row.unread_count = UInt64(clamping: workspace.unreadCount)
        row.status = add(status)
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

    /// `path` with this Mac's home as `~`; the request is built on the stack (a row map calls this per tab).
    func abbreviate(_ path: String) -> String {
        var path = path
        return path.withUTF8 { path in
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: home.count + path.count) { buffer in
                _ = buffer.initialize(fromContentsOf: home)
                _ = buffer[home.count...].initialize(fromContentsOf: path)
                let reply = cmux_sidebar_face_abbreviate(handle, CmuxSidebarFaceRange(offset: UInt32(clamping: home.count), len: UInt32(clamping: path.count)),
                                                         CmuxSidebarFaceRange(offset: 0, len: UInt32(clamping: home.count)), buffer.baseAddress, buffer.count)
                return Self.string(reply) ?? String(decoding: path, as: UTF8.self)
            }
        }
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
