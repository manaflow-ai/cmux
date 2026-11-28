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

    /// One open chat page: its machine and tab, the page, and whether it is a New Tab page (a chat with nothing in it).
    public typealias Chat = (machine: String, tab: String, view: AgentPaneView, newTab: Bool)

    /// The app's chat pages.
    let chats: @MainActor @Sendable () -> [Chat]
    /// The local daemon's pid.
    let daemonPid: @MainActor @Sendable () -> Int32?

    public init(chats: @escaping @MainActor @Sendable () -> [Chat],
                daemonPid: @escaping @MainActor @Sendable () -> Int32?) {
        self.chats = chats
        self.daemonPid = daemonPid
    }

    public var controlMethod: ControlMethod {
        let chats = chats
        let daemonPid = daemonPid
        return .mainActor(Self.method) { _ in
            .value(Self.handover(chats: chats(), appPid: ProcessInfo.processInfo.processIdentifier, daemonPid: daemonPid()))
        }
    }

    /// `pid` is null for a page with no WebKit WebContent process to name: not loaded yet, ended, or Chromium.
    @MainActor
    static func handover(chats: [Chat], appPid: Int32, daemonPid: Int32?) -> JSONValue {
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
            "daemon_pids": .array((daemonPid.map { $0 > 0 ? [$0] : [] } ?? []).map { .number(Double($0)) }),
            "chats": .array(rows),
        ])
    }
}
