public import AppKit
public import CmuxNextActions
public import CmuxNextAgentActivity
public import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextWakeups

/// What the app does for the Dock menu's rows; the App forwards each to the path its own
/// controls take (`palette.newAgentChat`, a `cmux://session/<id>` link).
@MainActor
public protocol DockMenuHost: AnyObject {
    /// This app's acpmux harnesses (`_acpmux/harnesses`), read off the main thread.
    func dockMenuHarnesses() async -> [AcpmuxHarnessRow]
    /// The machines a new chat can start on (this Mac, acpmux peers, Cloud machines).
    func dockMenuMachines() async -> [AgentChatDestinations.Destination]
    /// Whether any window is open, and whether the active one shows a pane a row can open in.
    var dockMenuWindow: DockMenuWindow { get }
    /// Brings the last closed window back, else opens a new one (a Dock click's reopen).
    func dockMenuReopenWindow()
    /// Runs New Agent Chat with `arguments` (`harness`, `host`), as Cmd-I and the palette do.
    func dockMenuNewChat(_ arguments: [String: ActionValue])
    /// Shows the tab that shows the chat, else opens it in a new agent tab; throws when it is gone.
    func dockMenuOpenChat(_ id: String) throws
    /// Says why a row could not run (the app's refusal toast).
    func dockMenuRefuse(_ reason: String)
}

/// The Dock icon's menu (`applicationDockMenu(_:)`), on by default: New Chat, New Chat in ▸
/// (harness, machine), Continue "<last chat>", then Unread and Recent sections of three chats
/// each with More ▸ (Leo 2026-11-03, after Claude's and Codex's Dock menus).
///
/// The menu never waits: `menu()` builds only from values this controller already holds. The
/// chats are rebuilt off the main thread from a copy of the lane store and the Priority marks
/// after they change, at most once a second while agents stream (the copy is a copy-on-write
/// handle; the filter and sort run detached). The harnesses and machines are read at `start()`
/// and again each time the menu opens, for the next open, never for this one.
@MainActor
public final class DockMenuController: NSObject {
    private let lanes: AgentLaneStore
    private let marks: AgentPriorityMarks
    private weak var host: (any DockMenuHost)?
    private let throttle: Duration
    /// The cached rows; `menu()` reads only these.
    public private(set) var chats = DockMenuChats.empty
    public private(set) var choices = DockMenuChoices.empty
    private var watch: Task<Void, Never>?
    private var choicesRead: Task<Void, Never>?
    /// A row picked while no window was open: it runs once the window that opened for it mounts
    /// its first pane (`windowDidShowContent`, called by the App's pane mount), with the harness or
    /// machine it named. A later pick replaces it.
    public private(set) var waiting: DockMenuAction?
    public var isWaiting: Bool { waiting != nil }

    public init(lanes: AgentLaneStore = .shared, marks: AgentPriorityMarks = .shared, host: any DockMenuHost,
                throttle: Duration = .seconds(1)) {
        self.lanes = lanes
        self.marks = marks
        self.host = host
        self.throttle = throttle
    }

    /// Starts keeping the rows current. Ends with `stop()` (app quit); the App owns the one instance.
    public func start() {
        guard watch == nil else { return }
        let (lanes, marks, throttle) = (lanes, marks, throttle)
        // task-owner: this controller; cancelled by stop()
        watch = Task { [weak self] in
            for await _ in ObservationStream({ _ = lanes.lanes; _ = marks.state }) {
                let (copy, state) = (lanes.lanes, marks.state)
                let made = await Task.detached(priority: WorkPriority.bestEffort.taskPriority) {
                    DockMenuChats.make(lanes: copy.values, marks: state)
                }.value
                guard !Task.isCancelled, let self else { return }
                if made != chats { chats = made }
                // wakeup-allow: one sleep per change burst while agents stream; the stream coalesces the changes meanwhile and nothing wakes when nothing changes
                try? await Task.sleep(for: throttle)
            }
        }
        refreshChoices()
    }

    public func stop() {
        watch?.cancel()
        watch = nil
        choicesRead?.cancel()
        choicesRead = nil
    }

    /// Reads the harnesses and machines again for the next menu (one read at a time).
    private func refreshChoices() {
        guard choicesRead == nil, let host else { return }
        // task-owner: this controller; one read at a time, cancelled by stop()
        choicesRead = Task { [weak self, weak host] in
            guard let host else { return }
            let harnesses = await host.dockMenuHarnesses()
            let machines = await host.dockMenuMachines()
            let made = DockMenuChoices.make(harnesses: harnesses, machines: machines)
            guard let self else { return }
            choicesRead = nil
            if !Task.isCancelled, made != choices { choices = made }
        }
    }

    /// The menu from the cached rows; also asks for fresh harnesses and machines for the next open.
    public func menu() -> NSMenu {
        defer { refreshChoices() }
        return DockMenuBuilder.menu(chats: chats, choices: choices, target: self, action: #selector(pick(_:)))
    }

    @objc private func pick(_ item: NSMenuItem) {
        guard let action = (item.representedObject as? DockMenuBuilder.Box)?.action else { return }
        NSApp.activate()
        run(action)
    }

    /// Runs `action` now when a window is open. With none, it opens one and the action waits
    /// for that window's first pane (`windowDidShowContent`), so New Chat in ▸ keeps its harness
    /// or machine and Continue, Unread and Recent open their chat instead of failing.
    func run(_ action: DockMenuAction) {
        guard let host else { return }
        guard host.dockMenuWindow != .closed else {
            // A plain New Chat needs nothing more: a new window comes with its New Tab page.
            guard action != .newChat(harness: nil, machine: nil) else {
                waiting = nil
                return host.dockMenuReopenWindow()
            }
            // Set before the reopen: a closed window brought back mounts its panes inside it.
            waiting = action
            host.dockMenuReopenWindow()
            // A chat a tab already shows opens with no pane (a window brought back on a top page
            // mounts none); else the pick waits for the first pane.
            if case .open(let chat) = action, (try? host.dockMenuOpenChat(chat)) != nil { waiting = nil }
            windowDidShowContent() // its pane may already show
            return
        }
        waiting = nil // a pick made while a window is open supersedes one still waiting
        perform(action, host)
    }

    /// A window mounted its first pane: a row picked while no window was open runs in it now.
    public func windowDidShowContent() {
        guard let action = waiting, let host, host.dockMenuWindow == .pane else { return }
        waiting = nil
        perform(action, host)
    }

    private func perform(_ action: DockMenuAction, _ host: any DockMenuHost) {
        switch action {
        case .newChat(let harness, let machine):
            var arguments: [String: ActionValue] = [:]
            if let harness { arguments["harness"] = .string(harness) }
            if let machine { arguments["host"] = .string(machine) }
            host.dockMenuNewChat(arguments)
        case .open(let chat):
            do { try host.dockMenuOpenChat(chat) } catch { host.dockMenuRefuse(String(describing: error)) }
        }
    }
}

/// The app's windows as the Dock menu's rows need them (`DockMenuHost.dockMenuWindow`).
public nonisolated enum DockMenuWindow: Equatable, Sendable {
    /// No window is open.
    case closed
    /// A window is open; the active one shows no pane yet.
    case noPane
    /// The active window shows a pane.
    case pane
}

/// What a Dock menu row does.
public nonisolated enum DockMenuAction: Equatable, Sendable {
    /// New Agent Chat; nil harness or machine: the person's default.
    case newChat(harness: String?, machine: String?)
    case open(chat: String)
}

/// New Chat in ▸'s rows: the harnesses that can start, then the machines that are ready.
public nonisolated struct DockMenuChoices: Equatable, Sendable {
    public struct Choice: Equatable, Sendable {
        public let id: String
        public let title: String

        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    public var harnesses: [Choice] = []
    /// Empty when this Mac is the only machine (the submenu then lists harnesses only).
    public var machines: [Choice] = []

    public init(harnesses: [Choice] = [], machines: [Choice] = []) {
        self.harnesses = harnesses
        self.machines = machines
    }

    public static let empty = DockMenuChoices()

    /// Chat harnesses (not `terminal`) with no known problem, by id; machines that are ready, listed only when there
    /// is one besides this Mac.
    @MainActor public static func make(harnesses: [AcpmuxHarnessRow], machines: [AgentChatDestinations.Destination]) -> DockMenuChoices {
        // A terminal harness opens a terminal, not a chat (#33727).
        let usable = harnesses.filter { $0.problem == nil && $0.kind != "terminal" }.sorted { $0.id < $1.id }
            .map { Choice(id: $0.id, title: $0.name ?? harnessTitle($0.id)) }
        let ready = machines.filter { $0.isReady && $0.route != .pending }.map { Choice(id: $0.id, title: $0.title) }
        return DockMenuChoices(harnesses: usable, machines: ready.count > 1 ? ready : [])
    }

    /// A harness's name for a row when its profile names none.
    public static func harnessTitle(_ id: String) -> String {
        switch id {
        case "claude": "Claude Code"
        case "codex": "Codex"
        case "opencode": "OpenCode"
        case "gemini": "Gemini"
        default: id.prefix(1).uppercased() + id.dropFirst()
        }
    }
}
