import CCmuxLayoutReducerFFI
import CmuxNextDaemon
import Foundation

/// The sidebar row face rules, which run in Rust (cmux-layout-reducer `sidebar_face`, through
/// `cmux_sidebar_face_*`): which tab a workspace's row stands for and is named for, its folder line
/// and Group by Folder bucket, its kinds, program, status line, unread mark, notice and progress bar,
/// and each listed tab's shortened title and folder. This type only encodes a workspace's tabs into
/// the C request (O(its tabs)) and reads the reply; it decides nothing. One handle for the app,
/// used on the main actor only. It keeps no Swift state: each call builds its request in local
/// buffers, and the Rust handle owns the reply's buffers (valid until the next call, read at once).
@MainActor
final class SidebarFaceRules {
    static let shared = SidebarFaceRules()

    /// No index, no string (`CMUX_SIDEBAR_FACE_NONE`).
    private static let none = UInt32.max
    /// No progress value (`CMUX_SIDEBAR_FACE_NO_VALUE`).
    private static let noValue = Int32.min

    /// The face of one row. Tab fields index the workspace's tabs in pane order; entry fields its
    /// status entries.
    struct Face {
        enum Notice { case attention(Int), notification(Int) }
        enum ListedKind { case record, newTab, agentChat }
        struct Listed {
            /// Nil: the tab keeps the list title the request gave it.
            var title: String?
            var folder: String?
            var kind: ListedKind
            /// A titled New Tab page: no folder, idle, no host.
            var blank: Bool
            var lastActivityMs: UInt64
        }

        var front: Int?
        var label: Int?
        var face: Int?
        var work: Int?
        var chat: Int?
        var folderTab: Int?
        var bucketTab: Int?
        var agent: Int?
        var notice: Notice?
        /// 0 terminal, 1 browser, 2 harness.
        var kind: UInt8 = 0
        /// 0 terminal, 1 browser, 2 agent, 3 mixed.
        var rowKind: UInt8 = 0
        /// 0 none, 1 dot, 2 the unread count.
        var unread: UInt8 = 0
        var progress: (value: Double?, isError: Bool)?
        var directory: String?
        var bucket: String?
        var process: String?
        var statusLine: String?
        var ports: Int?
        var pullRequest: Int?
        var statusEntries: [Int] = []
        var lastActivityMs: UInt64 = 0
        var tabs: [Listed] = []
    }

    /// What the app adds to a workspace's tabs for the rules.
    struct Inputs {
        var local: Bool
        var newTabPages: Set<String> = []
        /// The New Tab page has a title to list (`newTabTitle` not empty).
        var newTabTitled = false
        /// The title the tab list shows before the folder rule, one per tab in pane order
        /// (`TabTitleResolver`, a New Tab page's title, else the tab's display title); empty: each
        /// tab's display title.
        var listTitles: [String] = []
        /// The hooks' status line (`set_status`).
        var status: String?
        var showsUnread = true
    }

    private let handle: OpaquePointer?
    /// This Mac's home folder as UTF-8, read once.
    private let home: [UInt8]

    init(home: String = NSHomeDirectory()) {
        handle = cmux_sidebar_face_new()
        self.home = Array(home.utf8)
    }

    /// One call's request: the strings (this Mac's home folder first) and the struct arrays.
    private struct Request {
        var bytes: [UInt8]
        var tabs: [CmuxSidebarFaceTab] = []
        var panes: [CmuxSidebarFacePane] = []
        var entries: [CmuxSidebarFaceEntry] = []
        let home: CmuxSidebarFaceRange

        init(home: [UInt8]) {
            bytes = home
            self.home = CmuxSidebarFaceRange(offset: 0, len: UInt32(truncatingIfNeeded: home.count))
        }

        mutating func add(_ text: String?) -> CmuxSidebarFaceRange {
            guard let text else { return CmuxSidebarFaceRange(offset: SidebarFaceRules.none, len: 0) }
            let offset = UInt32(truncatingIfNeeded: bytes.count)
            bytes.append(contentsOf: text.utf8)
            return CmuxSidebarFaceRange(offset: offset, len: UInt32(truncatingIfNeeded: bytes.count) - offset)
        }
    }

    private static func kind(_ kind: TabKind) -> UInt8 {
        switch kind {
        case .pty: 0
        case .browser: 1
        case .remoteTerminal: 2
        case .conversation: 3
        case .other: 4
        }
    }

    private static func agent(_ state: AgentState?) -> UInt8 {
        switch state {
        case nil: 0
        case .working?: 1
        case .blocked?: 2
        case _?: 3
        }
    }

    private static func encode(_ tab: TabModel, at index: Int, _ inputs: Inputs, branded: Bool, into request: inout Request) -> CmuxSidebarFaceTab {
        var row = CmuxSidebarFaceTab()
        row.title = request.add(tab.titleText)
        row.list_title = request.add(inputs.listTitles.indices.contains(index) ? inputs.listTitles[index] : tab.displayTitle)
        row.cwd = request.add(tab.cwd)
        var flags: UInt32 = 0
        if !(tab.name ?? "").isEmpty { flags |= 1 }
        if tab.agentSession != nil { flags |= 2 }
        if tab.commandSinceMs != nil { flags |= 4 }
        if tab.titleActivity != nil { flags |= 8 }
        if tab.page != nil { flags |= 16 }
        if tab.appTab != nil { flags |= 32 }
        if inputs.newTabPages.contains(tab.id) { flags |= 64 }
        if branded { flags |= 128 }
        if tab.hasUnread { flags |= 256 }
        if tab.markedUnread { flags |= 512 }
        if let attention = tab.attention {
            flags |= 1024
            row.attention_at_ms = attention.atMs
        }
        row.flags = flags
        row.kind = Self.kind(tab.kind)
        row.agent = Self.agent(tab.agent?.state)
        row.progress_value = Self.noValue
        if let progress = tab.progress {
            row.progress_state = switch progress.state {
            case .normal: 1
            case .error: 2
            case .indeterminate: 3
            case .paused: 4
            }
            if let value = progress.value { row.progress_value = Int32(clamping: value) }
        }
        row.notification = tab.notification?.notification.rawValue ?? 0
        row.agent_updated_ms = tab.agent?.updatedAtMs ?? 0
        row.notification_created_ms = tab.notification?.createdAtMs ?? 0
        return row
    }

    /// The face of `workspace`'s row. `selectedTab` is the window's tab selection in a pane;
    /// `branded`: the tab's agent has a brand mark or its chat's harness its own icon. Nil only when
    /// the rules could not read the request.
    func face(_ workspace: WorkspaceModel, _ inputs: Inputs, selectedTab: (PaneModel) -> String?,
              branded: (TabModel) -> Bool = { $0.agentBrand != nil }) -> Face? {
        var request = Request(home: home)
        for screen in workspace.screens {
            for pane in screen.panes {
                var row = CmuxSidebarFacePane()
                row.focused_at = pane.focusedAt
                row.default_tab = Int64(pane.defaultTabIndex)
                row.tab_count = UInt32(truncatingIfNeeded: pane.tabs.count)
                row.selected = selectedTab(pane).flatMap { id in pane.tabs.firstIndex { $0.id == id } }
                    .map { UInt32(truncatingIfNeeded: $0) } ?? Self.none
                request.panes.append(row)
                for tab in pane.tabs {
                    request.tabs.append(Self.encode(tab, at: request.tabs.count, inputs, branded: branded(tab), into: &request))
                }
            }
        }
        let status = workspace.status
        for entry in status?.entries ?? [] {
            let key = request.add(entry.key), text = request.add(entry.text)
            request.entries.append(CmuxSidebarFaceEntry(key: key, text: text))
        }
        var row = CmuxSidebarFaceWorkspace()
        row.pane_count = UInt32(truncatingIfNeeded: request.panes.count)
        row.tab_count = UInt32(truncatingIfNeeded: request.tabs.count)
        row.entry_count = UInt32(truncatingIfNeeded: request.entries.count)
        row.flags = (inputs.local ? 1 : 0) | (workspace.markedUnread ? 2 : 0)
        if let reported = status?.progress {
            row.flags |= 4
            row.reported_progress = reported.value ?? .nan
        }
        row.unread_count = UInt64(max(workspace.unreadCount, 0))
        row.status = request.add(inputs.status)
        return call([row], request, inputs: inputs)
    }

    private func call(_ workspaces: [CmuxSidebarFaceWorkspace], _ built: Request, inputs: Inputs) -> Face? {
        guard let handle else { return nil }
        let reply: UnsafePointer<CmuxSidebarFaceReply>? = workspaces.withUnsafeBufferPointer { workspaces in
            built.panes.withUnsafeBufferPointer { panes in
                built.tabs.withUnsafeBufferPointer { tabs in
                    built.entries.withUnsafeBufferPointer { entries in
                        built.bytes.withUnsafeBufferPointer { strings in
                            var request = CmuxSidebarFaceRequest()
                            request.workspaces = workspaces.baseAddress
                            request.panes = panes.baseAddress
                            request.tabs = tabs.baseAddress
                            request.entries = entries.baseAddress
                            request.workspace_count = UInt32(truncatingIfNeeded: workspaces.count)
                            request.pane_count = UInt32(truncatingIfNeeded: panes.count)
                            request.tab_count = UInt32(truncatingIfNeeded: tabs.count)
                            request.entry_count = UInt32(truncatingIfNeeded: entries.count)
                            request.home = built.home
                            request.shows_unread = inputs.showsUnread ? 1 : 0
                            request.new_tab_titled = inputs.newTabTitled ? 1 : 0
                            return cmux_sidebar_face_rows(handle, &request, strings.baseAddress, strings.count)
                        }
                    }
                }
            }
        }
        guard let reply = reply?.pointee, reply.ok != 0, reply.face_count == 1, let row = reply.faces?.pointee else { return nil }
        return Self.read(row, reply)
    }

    private static func index(_ value: UInt32) -> Int? { value == none ? nil : Int(value) }

    private static func text(_ range: CmuxSidebarFaceRange, _ reply: CmuxSidebarFaceReply) -> String? {
        guard range.offset != none, let strings = reply.strings,
              Int(range.offset) + Int(range.len) <= Int(reply.strings_len) else { return nil }
        return String(decoding: UnsafeBufferPointer(start: strings + Int(range.offset), count: Int(range.len)), as: UTF8.self)
    }

    private static func read(_ row: CmuxSidebarFaceRow, _ reply: CmuxSidebarFaceReply) -> Face {
        var face = Face()
        face.front = index(row.front)
        face.label = index(row.label)
        face.face = index(row.face)
        face.work = index(row.work)
        face.chat = index(row.chat)
        face.folderTab = index(row.folder_tab)
        face.bucketTab = index(row.bucket_tab)
        face.agent = index(row.agent)
        face.notice = switch (row.notice, index(row.notice_tab)) {
        case (1, let tab?): .attention(tab)
        case (2, let tab?): .notification(tab)
        default: nil
        }
        face.kind = row.kind
        face.rowKind = row.row_kind
        face.unread = row.unread
        if row.progress != 0 {
            face.progress = (row.progress_value.isNaN ? nil : row.progress_value, row.progress_error != 0)
        }
        face.directory = text(row.directory, reply)
        face.bucket = text(row.bucket, reply)
        face.process = text(row.process, reply)
        face.statusLine = text(row.status_line, reply)
        face.ports = index(row.ports)
        face.pullRequest = index(row.pull_request)
        face.lastActivityMs = row.last_activity_ms
        if let kept = reply.kept_entries, row.kept_entry_count > 0,
           Int(row.kept_entry_start) + Int(row.kept_entry_count) <= Int(reply.kept_entry_count) {
            face.statusEntries = (0 ..< Int(row.kept_entry_count)).map { Int(kept[Int(row.kept_entry_start) + $0]) }
        }
        if let listed = reply.listed {
            let start = Int(row.listed_start)
            let count = max(0, Int(reply.listed_count) - start)
            face.tabs = (0 ..< count).map { offset in
                let tab = listed[start + offset]
                return Face.Listed(
                    title: tab.flags & 1 != 0 ? text(tab.title, reply) : nil,
                    folder: text(tab.folder, reply),
                    kind: switch tab.kind {
                    case 1: .newTab
                    case 2: .agentChat
                    default: .record
                    },
                    blank: tab.flags & 2 != 0,
                    lastActivityMs: tab.last_activity_ms)
            }
        }
        return face
    }

    /// `path` with this Mac's home as `~` (`sidebar_face::abbreviate`). The request is built on the
    /// stack: a row map calls this per tab, and a sidebar remap 20,000 times (SidebarAbbreviateCostTests).
    func abbreviate(_ path: String) -> String {
        guard let handle else { return path }
        var path = path
        return path.withUTF8 { path in
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: home.count + path.count) { buffer in
                _ = buffer.initialize(fromContentsOf: home)
                _ = buffer[home.count...].initialize(fromContentsOf: path)
                let homeRange = CmuxSidebarFaceRange(offset: 0, len: UInt32(truncatingIfNeeded: home.count))
                let pathRange = CmuxSidebarFaceRange(offset: UInt32(truncatingIfNeeded: home.count), len: UInt32(truncatingIfNeeded: path.count))
                let reply = cmux_sidebar_face_abbreviate(handle, pathRange, homeRange, buffer.baseAddress, buffer.count)
                return Self.string(reply) ?? String(decoding: path, as: UTF8.self)
            }
        }
    }

    /// The daemon's next default workspace name (`sidebar_face::default_workspace_name`).
    func defaultWorkspaceName(existing: [String], reserved: [String]) -> String {
        var request = Request(home: [])
        let names = (existing + reserved).map { request.add($0) }
        let reply = names.withUnsafeBufferPointer { names in
            request.bytes.withUnsafeBufferPointer { strings in
                cmux_sidebar_face_default_name(handle, names.baseAddress, UInt32(truncatingIfNeeded: names.count),
                                               UInt32(truncatingIfNeeded: existing.count), strings.baseAddress, strings.count)
            }
        }
        return Self.string(reply) ?? SidebarMapping.defaultNamePrefix + String(existing.count + reserved.count + 1)
    }

    private static func string(_ reply: UnsafePointer<CmuxSidebarFaceText>?) -> String? {
        guard let text = reply?.pointee, text.ok != 0, let bytes = text.bytes else { return nil }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(text.len)), as: UTF8.self)
    }
}
