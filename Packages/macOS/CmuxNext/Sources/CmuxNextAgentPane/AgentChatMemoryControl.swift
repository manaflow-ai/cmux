public import CmuxNextControl
public import CmuxNextSettings
import Foundation

/// `agent.chat.memory` on the app control socket (`cmux app chat memory`, every build): the process ids the
/// CLI needs to read each open agent chat's memory, and nothing else. The App only hands over pids; the CLI
/// (Rust, cmux-tui `cli/app/chat_memory.rs`) reads each process's physical footprint, groups pages that
/// share one WebContent process so it counts once, and works out the ratio against an empty chat's page.
/// Read-only and on request: it never shows, loads or wakes a page, and keeps no timer or sample.
public struct AgentChatMemoryControl: Sendable {
    public nonisolated static let method = "agent.chat.memory"

    /// One open chat the App holds a page for.
    public struct Chat {
        public var tab: String
        public var machine: String
        public var view: AgentPaneView
        /// The page is the New Tab page (a chat with nothing in it yet).
        public var newTab: Bool

        public init(tab: String, machine: String, view: AgentPaneView, newTab: Bool) {
            self.tab = tab
            self.machine = machine
            self.view = view
            self.newTab = newTab
        }
    }

    let chats: @MainActor @Sendable () -> [Chat]
    let daemonPids: @MainActor @Sendable () -> [Int32]

    public init(chats: @escaping @MainActor @Sendable () -> [Chat], daemonPids: @escaping @MainActor @Sendable () -> [Int32]) {
        self.chats = chats
        self.daemonPids = daemonPids
    }

    public var controlMethod: ControlMethod {
        let chats = chats
        let daemonPids = daemonPids
        return .mainActor(Self.method) { _ in
            .value(Self.handover(chats: chats(), appPid: ProcessInfo.processInfo.processIdentifier, daemonPids: daemonPids()))
        }
    }

    /// `pid` is null for a page with no WebKit WebContent process to name: not loaded yet, ended, or Chromium.
    @MainActor
    static func handover(chats: [Chat], appPid: Int32, daemonPids: [Int32]) -> JSONValue {
        let rows: [JSONValue] = chats.sorted { ($0.machine, $0.tab) < ($1.machine, $1.tab) }.map { chat in
            let pid = chat.view.flickerPid
            return .object([
                "tab": .string(chat.tab),
                "machine": .string(chat.machine),
                "pid": pid > 0 ? .number(Double(pid)) : .null,
                "new_tab": .bool(chat.newTab),
                "frozen": .bool(chat.view.pageIsFrozen),
            ])
        }
        return .object([
            "app_pid": .number(Double(appPid)),
            "daemon_pids": .array(Array(Set(daemonPids)).sorted().map { .number(Double($0)) }),
            "chats": .array(rows),
        ])
    }
}
