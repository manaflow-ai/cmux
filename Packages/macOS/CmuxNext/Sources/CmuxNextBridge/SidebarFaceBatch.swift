internal import CCmuxLayoutReducerFFI
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSidebar
import Foundation

/// The sidebar row face of many rows in one Rust call (`cmux_sidebar_face_rows`, cmux-layout-reducer
/// `sidebar_face`). It encodes each row's workspace (O(its tabs)) into fixed-size C structs and one UTF-8
/// buffer, calls once for the whole batch, and decodes each row's face. It decides nothing: the closures
/// `SidebarMapping.sections` and `row` take are run by the caller first and reach it as strings and flags. Every buffer
/// is kept and reused from batch to batch, and the Rust handle reuses its reply buffers, so a frame's batch
/// allocates only when it is larger than every batch before it. Main actor only: the reply belongs to the
/// handle and is read before the next call. A window's sidebar keeps one (`SidebarMapping.sections(faces:)`), so its
/// buffers last from pass to pass.
public final class SidebarFaceBatch {
    static let none = UInt32.max
    private static let absent = CmuxSidebarFaceRange(offset: none, len: 0)

    /// The header's `CMUX_SIDEBAR_FACE_*` bits.
    enum Bit {
        static let named: UInt32 = 1, chat: UInt32 = 2, commandRunning: UInt32 = 4, titleActivity: UInt32 = 8
        static let page: UInt32 = 16, app: UInt32 = 32, newTabPage: UInt32 = 64, branded: UInt32 = 128
        static let hasUnread: UInt32 = 256, markedUnread: UInt32 = 512, attention: UInt32 = 1024
        static let local: UInt32 = 1, workspaceMarkedUnread: UInt32 = 2, reportedProgress: UInt32 = 4
    }

    /// The face handle's address (0: none), a plain value, so the nonisolated deinit can free it.
    private let handleAddress = UInt(bitPattern: cmux_sidebar_face_new())
    private var handle: OpaquePointer? { OpaquePointer(bitPattern: handleAddress) }

    private var workspaces: [CmuxSidebarFaceWorkspace] = []
    private var panes: [CmuxSidebarFacePane] = []
    private var faceTabs: [CmuxSidebarFaceTab] = []
    private var entries: [CmuxSidebarFaceEntry] = []
    private var strings: [UInt8] = []
    private let homeRange: CmuxSidebarFaceRange
    /// This Mac's home folder, UTF-8: what the rules shorten to `~` on a local row.
    let home: [UInt8]
    private var showsUnread = true
    private var newTabTitled = false
    /// Every row's tabs in pane order, and the title the tab list shows for each before a folder title is
    /// shortened (`tabTitle`, a New Tab page's title, else the display title): the row assembly reads both.
    private(set) var tabs: [TabModel] = []
    private(set) var listTitles: [String] = []
    /// Held by a row batch between its begin and its run (`SidebarMapping.FaceRowBatch`); a batch begun meanwhile
    /// takes buffers of its own.
    var inUse = false

    /// `home`: the folder local rows shorten to `~` (nil: this Mac's home).
    public init(home: String? = nil) {
        self.home = Array((home ?? NSHomeDirectory()).utf8)
        homeRange = CmuxSidebarFaceRange(offset: 0, len: UInt32(clamping: self.home.count))
    }

    nonisolated deinit { cmux_sidebar_face_free(OpaquePointer(bitPattern: handleAddress)) }

    /// The number of rows in the batch.
    var count: Int { workspaces.count }

    /// The tabs of row `row` (in the order its face's tab indexes count).
    func tabRange(_ row: Int) -> Range<Int> {
        let start = Int(workspaces[row].tab_start)
        return start ..< start + Int(workspaces[row].tab_count)
    }

    /// Empties the batch, keeping every buffer's capacity.
    func reset(showsUnread: Bool, newTabTitled: Bool) {
        workspaces.removeAll(keepingCapacity: true)
        panes.removeAll(keepingCapacity: true)
        faceTabs.removeAll(keepingCapacity: true)
        entries.removeAll(keepingCapacity: true)
        strings.removeAll(keepingCapacity: true)
        tabs.removeAll(keepingCapacity: true)
        listTitles.removeAll(keepingCapacity: true)
        strings.append(contentsOf: home)
        self.showsUnread = showsUnread
        self.newTabTitled = newTabTitled
    }

    private func add(_ text: String?) -> CmuxSidebarFaceRange {
        guard let text else { return Self.absent }
        let offset = strings.count
        strings.append(contentsOf: text.utf8)
        return CmuxSidebarFaceRange(offset: UInt32(clamping: offset), len: UInt32(clamping: strings.count - offset))
    }

    /// Adds one row. `listTitle` is the tab list's title of a tab (`tabTitle`, else a New Tab page's title, else
    /// its display title); `branded` whether its agent has a brand mark or its chat's harness its own icon.
    func append(_ workspace: WorkspaceModel, local: Bool, status: String?, selectedTab: (PaneModel) -> String?,
                newTabPages: Set<String>, listTitle: (TabModel) -> String, branded: (TabModel) -> Bool) {
        var row = CmuxSidebarFaceWorkspace()
        row.pane_start = UInt32(clamping: panes.count)
        row.tab_start = UInt32(clamping: faceTabs.count)
        row.entry_start = UInt32(clamping: entries.count)
        for screen in workspace.screens {
            for pane in screen.panes {
                let selected = selectedTab(pane).flatMap { id in pane.tabs.firstIndex { $0.id == id } }
                panes.append(CmuxSidebarFacePane(focused_at: pane.focusedAt, default_tab: Int64(pane.defaultTabIndex),
                                                 tab_count: UInt32(clamping: pane.tabs.count),
                                                 selected: selected.map { UInt32(clamping: $0) } ?? Self.none))
                for tab in pane.tabs {
                    let title = listTitle(tab)
                    faceTabs.append(encode(tab, newTabPage: newTabPages.contains(tab.id), listTitle: title, branded: branded(tab)))
                    tabs.append(tab)
                    listTitles.append(title)
                }
            }
        }
        if let status = workspace.status {
            for entry in status.entries {
                let key = add(entry.key)
                entries.append(CmuxSidebarFaceEntry(key: key, text: add(entry.text)))
            }
            if let progress = status.progress {
                row.flags |= Bit.reportedProgress
                row.reported_progress = progress.value ?? .nan
            }
        }
        if local { row.flags |= Bit.local }
        if workspace.markedUnread { row.flags |= Bit.workspaceMarkedUnread }
        row.unread_count = UInt64(clamping: max(workspace.unreadCount, 0))
        row.status = add(status)
        row.pane_count = UInt32(clamping: panes.count) - row.pane_start
        row.tab_count = UInt32(clamping: faceTabs.count) - row.tab_start
        row.entry_count = UInt32(clamping: entries.count) - row.entry_start
        workspaces.append(row)
    }

    private func encode(_ tab: TabModel, newTabPage: Bool, listTitle: String, branded: Bool) -> CmuxSidebarFaceTab {
        var row = CmuxSidebarFaceTab()
        var flags: UInt32 = 0
        func mark(_ on: Bool, _ bit: UInt32) { if on { flags |= bit } }
        row.kind = switch tab.kind {
        case .pty: 0
        case .browser: 1
        case .remoteTerminal: 2
        case .conversation: 3
        case .other: 4
        }
        row.title = add(tab.titleText)
        row.list_title = add(listTitle)
        row.cwd = add(tab.cwd)
        mark(!(tab.name?.isEmpty ?? true), Bit.named)
        mark(tab.agentSession != nil, Bit.chat)
        mark(tab.commandSinceMs != nil, Bit.commandRunning)
        mark(tab.titleActivity != nil, Bit.titleActivity)
        mark(tab.page != nil, Bit.page)
        mark(tab.appTab != nil, Bit.app)
        mark(newTabPage, Bit.newTabPage)
        mark(branded, Bit.branded)
        mark(tab.hasUnread, Bit.hasUnread)
        mark(tab.markedUnread, Bit.markedUnread)
        mark(tab.attention != nil, Bit.attention)
        row.flags = flags
        row.agent = switch tab.agent?.state {
        case nil: 0
        case .working?: 1
        case .blocked?: 2
        case _?: 3
        }
        row.progress_state = switch tab.progress?.state {
        case nil: 0
        case .normal?: 1
        case .error?: 2
        case .indeterminate?: 3
        case .paused?: 4
        }
        // Int32.min is the no-value marker; a report below it clamps one above.
        row.progress_value = tab.progress?.value.map { Int32(clamping: max($0, Int(Int32.min) + 1)) } ?? Int32.min
        row.notification = tab.notification?.notification.rawValue ?? 0
        row.attention_at_ms = tab.attention?.atMs ?? 0
        row.agent_updated_ms = tab.agent?.updatedAtMs ?? 0
        row.notification_created_ms = tab.notification?.createdAtMs ?? 0
        return row
    }

    /// Maps every row of the batch in one call. Nil when the rules could not read the request.
    func run() -> Reply? {
        let reply: UnsafePointer<CmuxSidebarFaceReply>? = workspaces.withUnsafeBufferPointer { workspaces in
            panes.withUnsafeBufferPointer { panes in
                faceTabs.withUnsafeBufferPointer { tabs in
                    entries.withUnsafeBufferPointer { entries in
                        strings.withUnsafeBufferPointer { bytes in
                            var request = CmuxSidebarFaceRequest()
                            request.workspaces = workspaces.baseAddress
                            request.panes = panes.baseAddress
                            request.tabs = tabs.baseAddress
                            request.entries = entries.baseAddress
                            request.workspace_count = UInt32(clamping: workspaces.count)
                            request.pane_count = UInt32(clamping: panes.count)
                            request.tab_count = UInt32(clamping: tabs.count)
                            request.entry_count = UInt32(clamping: entries.count)
                            request.home = homeRange
                            request.shows_unread = showsUnread ? 1 : 0
                            request.new_tab_titled = newTabTitled ? 1 : 0
                            return cmux_sidebar_face_rows(handle, &request, bytes.baseAddress, bytes.count)
                        }
                    }
                }
            }
        }
        guard let reply, reply.pointee.ok != 0, Int(reply.pointee.face_count) == workspaces.count else { return nil }
        return Reply(reply: reply.pointee)
    }

    /// The handle's reply: valid until the next ``run()``.
    struct Reply {
        let reply: CmuxSidebarFaceReply

        func text(_ range: CmuxSidebarFaceRange) -> String? {
            guard range.offset != SidebarFaceBatch.none, UInt64(range.offset) + UInt64(range.len) <= UInt64(reply.strings_len),
                  let strings = reply.strings else { return nil }
            return String(decoding: UnsafeBufferPointer(start: strings + Int(range.offset), count: Int(range.len)), as: UTF8.self)
        }

        private static func index(_ value: UInt32) -> Int? { value == SidebarFaceBatch.none ? nil : Int(value) }

        /// Row `row`'s face, with `tabCount` listed tabs.
        func face(_ row: Int, tabCount: Int) -> SidebarFace {
            let raw = reply.faces[row]
            var face = SidebarFace()
            face.front = Self.index(raw.front)
            face.label = Self.index(raw.label)
            face.face = Self.index(raw.face)
            face.work = Self.index(raw.work)
            face.chat = Self.index(raw.chat)
            face.folderTab = Self.index(raw.folder_tab)
            face.bucketTab = Self.index(raw.bucket_tab)
            face.agent = Self.index(raw.agent)
            face.notice = switch raw.notice {
            case 1: Self.index(raw.notice_tab).map(SidebarFace.Notice.attention)
            case 2: Self.index(raw.notice_tab).map(SidebarFace.Notice.notification)
            default: nil
            }
            face.kind = switch raw.kind {
            case 1: .browser
            case 2: .harness
            default: .terminal
            }
            face.rowKind = switch raw.row_kind {
            case 1: .browser
            case 2: .agent
            case 3: .mixed
            default: .terminal
            }
            face.unread = raw.unread
            face.progress = raw.progress == 0 ? nil
                : SidebarProgress(value: raw.progress_value.isNaN ? nil : raw.progress_value, isError: raw.progress_error != 0)
            face.directory = text(raw.directory)
            face.bucket = text(raw.bucket)
            face.process = text(raw.process)
            face.statusLine = text(raw.status_line)
            face.ports = Self.index(raw.ports)
            face.pullRequest = Self.index(raw.pull_request)
            face.lastActivityMs = raw.last_activity_ms
            let kept = Int(raw.kept_entry_start)
            if raw.kept_entry_count > 0, kept + Int(raw.kept_entry_count) <= Int(reply.kept_entry_count) {
                face.statusEntries = (kept ..< kept + Int(raw.kept_entry_count)).map { Int(reply.kept_entries[$0]) }
            }
            let start = Int(raw.listed_start)
            if start != Int(SidebarFaceBatch.none), start + tabCount <= Int(reply.listed_count) {
                face.listed.reserveCapacity(tabCount)
                for index in start ..< start + tabCount {
                    let listed = reply.listed[index]
                    face.listed.append(SidebarFace.Listed(
                        title: listed.flags & 1 != 0 ? text(listed.title) : nil,
                        folder: text(listed.folder),
                        kind: listed.kind,
                        blank: listed.flags & 2 != 0,
                        lastActivityMs: listed.last_activity_ms))
                }
            }
            return face
        }
    }
}

/// One row's face as the Rust rules answer it (`cmux_layout_reducer::sidebar_face::Face`). Tab fields index the
/// row's tabs in pane order; entry fields its workspace status entries.
struct SidebarFace: Equatable {
    enum Notice: Equatable {
        case attention(Int)
        case notification(Int)
    }

    struct Listed: Equatable {
        /// Nil: the tab keeps its list title (the rules shortened no folder title).
        var title: String?
        var folder: String?
        /// 0 the record's kind, 1 a New Tab page, 2 an agent chat.
        var kind: UInt8
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
    var kind: SidebarWorkspaceKind = .terminal
    var rowKind: WorkspaceRowKind = .terminal
    /// 0 none, 1 a dot, 2 the workspace's unread count.
    var unread: UInt8 = 0
    var progress: SidebarProgress?
    var directory: String?
    var bucket: String?
    var process: String?
    var statusLine: String?
    var ports: Int?
    var pullRequest: Int?
    var statusEntries: [Int] = []
    var lastActivityMs: UInt64 = 0
    var listed: [Listed] = []
}
