public import Foundation

/// Sample tabs for demos and tests of Search Tabs: terminals, pages and a
/// remote terminal across two windows, plus closed tabs. Records what the
/// page asked it to do.
public final class MockTabSearchSource: TabSearchSource {
    public var entries: [TabSearchEntry]
    public private(set) var focused: [String] = []
    public private(set) var closed: [String] = []
    public private(set) var reopened: [String] = []
    public private(set) var forgotten: [String] = []

    private var continuations: [AsyncStream<Void>.Continuation] = []

    public init(entries: [TabSearchEntry]? = nil, now: Date = Date()) {
        self.entries = entries ?? Self.sample(now: now)
    }

    public func changes() -> AsyncStream<Void> {
        // A change is a signal, not data: the newest one is enough.
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in continuations.append(continuation) }
    }

    /// Announces a change to the entries, as an owner's event would.
    public func emitChange() {
        for continuation in continuations { continuation.yield() }
    }

    public func tabSearchEntries() -> [TabSearchEntry] { entries }

    public func focusTab(id: String) { focused.append(id) }

    public func closeTab(id: String) {
        closed.append(id)
        entries.removeAll { $0.id == id && !$0.isClosed }
    }

    public func reopenClosedTab(id: String) { reopened.append(id) }

    public func forgetClosedTab(id: String) {
        forgotten.append(id)
        entries.removeAll { $0.id == id && $0.isClosed }
    }

    public static func sample(now: Date) -> [TabSearchEntry] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let home = NSHomeDirectory()
        return [
            TabSearchEntry(id: "tab_1", kind: .terminal, title: "claude", cwd: home + "/src/api", process: "claude",
                           workspaceID: "ws_api", workspaceTitle: "api", order: 0, state: .open(isCurrent: true, lastActive: ago(0))),
            TabSearchEntry(id: "tab_2", kind: .browser, title: "Pull requests · manaflow-ai/cmux",
                           url: "https://github.com/manaflow-ai/cmux/pulls", workspaceID: "ws_api", workspaceTitle: "api", order: 1,
                           state: .open(isCurrent: false, lastActive: ago(3))),
            TabSearchEntry(id: "tab_3", kind: .terminal, title: "bun dev", cwd: home + "/src/web", process: "bun",
                           workspaceID: "ws_web", workspaceTitle: "web", order: 2, state: .open(isCurrent: false, lastActive: ago(12))),
            TabSearchEntry(id: "tab_4", kind: .browser, title: "localhost:3000", url: "http://localhost:3000/dashboard",
                           workspaceID: "ws_web", workspaceTitle: "web", order: 3, state: .open(isCurrent: false, lastActive: ago(15))),
            TabSearchEntry(id: "tab_5", kind: .remoteTerminal, title: "cargo test", cwd: "/home/dev/cmux-tui", process: "cargo",
                           workspaceID: "ws_box", workspaceTitle: "build box", windowTitle: "Window 2", machine: "mac-mini",
                           order: 4, state: .open(isCurrent: false, lastActive: ago(40))),
            TabSearchEntry(id: "tab_6", kind: .terminal, title: "zsh", cwd: home, workspaceID: "ws_box", workspaceTitle: "build box",
                           windowTitle: "Window 2", order: 5, state: .open(isCurrent: false, lastActive: nil)),
            TabSearchEntry(id: "local/tab_7", kind: .browser, title: "Swift Testing", url: "https://developer.apple.com/xcode/swift-testing/",
                           workspaceTitle: "api", order: 6, state: .closed(closedAt: ago(2))),
            TabSearchEntry(id: "local/tab_8", kind: .terminal, title: "htop", cwd: home + "/src/api", process: "htop",
                           workspaceTitle: "api", order: 7, state: .closed(closedAt: ago(30))),
        ]
    }
}
