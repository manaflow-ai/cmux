import CmuxMobileModel
import Foundation

/// The one question a tab close can ask, as the cmux-next Mac app asks it
/// (`CmuxNextApp/Handlers/TabCloseGuard.swift`, #17501): only while a closing
/// terminal is doing work. A working agent in it (or one waiting on an answer)
/// is that agent's question ("Codex is still working."); else a foreground
/// program other than the login shell, which the Mac reports through
/// `process-info` (`foreground_executable`), asks "Still running: sleep.".
/// Idle shells, ended shells, browser tabs and agent chats close at once.
/// The title is never read: a Codex named by its thread, `sleep` or `yes`
/// under zsh's title all asked nothing before (round 11 N2/A1), and since a
/// phone close ends the terminal (`close-terminal`) that stopped them.
public struct TabCloseGuard: Sendable {
    public init() {}

    public struct Prompt: Equatable, Sendable {
        public var title: String
        public var message: String
    }

    /// The terminals whose foreground program the Mac is asked for: live
    /// terminal tabs with no working agent (an agent's tab is its own question).
    public func terminalsToAsk(_ tabs: [WorkspaceTab]) -> [WorkspaceTab] {
        tabs.filter { $0.kind == .terminal && !$0.hasEndedShell && workingAgent($0) == nil }
    }

    /// The display name of an agent working (or waiting on a permission or a
    /// question) in `tab`'s terminal, else nil. An unnamed agent reads "The agent".
    public func workingAgent(_ tab: WorkspaceTab) -> String? {
        guard tab.kind == .terminal, !tab.hasEndedShell else { return nil }
        let working = tab.agentStatus == .working || (tab.agentStatus == .waiting && tab.waitingFor != nil)
        guard working else { return nil }
        guard let harness = tab.harness, !harness.isEmpty else { return "The agent" }
        return tab.agentName
    }

    /// The question for closing `tabs` (one tab or a group), given the
    /// programs the Mac reported for `terminalsToAsk(tabs)`; nil closes at once.
    public func prompt(closing tabs: [WorkspaceTab], programs: [String]) -> Prompt? {
        let title = tabs.count == 1 ? "Close \u{201C}\(tabs[0].title)\u{201D}?" : "Close \(tabs.count) tabs?"
        if let agent = tabs.lazy.compactMap(workingAgent).first {
            return Prompt(title: title, message: "\(agent) is still working.")
        }
        let unique = Set(programs.filter { !$0.isEmpty }).sorted()
        guard !unique.isEmpty else { return nil }
        return Prompt(title: title, message: "Still running: \(unique.joined(separator: ", ")).")
    }

    /// `process-info`'s foreground program when it is not the terminal's own
    /// shell, else nil.
    public static func runningProgram(foregroundExecutable: String?, command: String?) -> String? {
        TerminalProcessInfo(command: command, foregroundExecutable: foregroundExecutable).runningProgram
    }
}

/// The foreground programs the Mac last reported per terminal tab
/// (`process-info`), read when the grid opens so a close of a busy tab asks
/// at once (full verify 2026-10-19 D7: the question came 2.1-2.4 s after the
/// tap). Entries older than `maxAge` are unknown.
public struct TabProgramCache: Sendable {
    public static let maxAge: Double = 5
    private var entries: [String: (programs: [String], at: Double)] = [:]

    public init() {}

    public mutating func record(tabID: String, programs: [String], at time: Double) {
        entries[tabID] = (programs, time)
    }

    public mutating func forget(tabID: String) {
        entries[tabID] = nil
    }

    /// The programs of all `tabIDs` (sorted, unique), or nil when any is unknown or stale.
    public func programs(of tabIDs: [String], now: Double) -> [String]? {
        var all = Set<String>()
        for id in tabIDs {
            guard let entry = entries[id], now - entry.at <= Self.maxAge else { return nil }
            all.formUnion(entry.programs.filter { !$0.isEmpty })
        }
        return all.sorted()
    }
}

/// What a close shows and when (D7): a working agent, or a program the grid
/// already knows about, asks at once (`immediate`). Otherwise the Mac is
/// asked; if it has not answered within `pendingAfter` the question shows as
/// pending (`pending`), and the reply then fills it in, or closes the tab
/// when the shell is idle (`afterReply`).
public struct TabClosePromptPlan: Sendable {
    public static let pendingAfter: Duration = .milliseconds(250)
    public static let checkingMessage = "Checking what\u{2019}s running on the Mac\u{2026}"

    public enum Outcome: Equatable, Sendable {
        case ask(TabCloseGuard.Prompt)
        case close
    }

    private let tabs: [WorkspaceTab]
    private let guardrail = TabCloseGuard()
    public let immediate: TabCloseGuard.Prompt?

    public init(closing tabs: [WorkspaceTab], cached: [String]?) {
        self.tabs = tabs
        let guardrail = TabCloseGuard()
        if tabs.contains(where: { guardrail.workingAgent($0) != nil }) {
            immediate = guardrail.prompt(closing: tabs, programs: [])
        } else if let cached, !cached.isEmpty {
            immediate = guardrail.prompt(closing: tabs, programs: cached)
        } else {
            immediate = nil
        }
    }

    /// The question while the Mac is being asked.
    public var pending: TabCloseGuard.Prompt {
        TabCloseGuard.Prompt(title: tabs.count == 1 ? "Close \u{201C}\(tabs[0].title)\u{201D}?" : "Close \(tabs.count) tabs?",
                             message: Self.checkingMessage)
    }

    /// The Mac answered with `programs`. A question already asked from the
    /// cache stays asked (an idle reply never closes a tab the person was asked about).
    public func afterReply(programs: [String]) -> Outcome {
        if let prompt = guardrail.prompt(closing: tabs, programs: programs) { return .ask(prompt) }
        if let immediate { return .ask(immediate) }
        return .close
    }
}
