import CmuxNextActions
import CmuxNextSettings

/// A quit request that names both choices.
struct QuitArgumentConflict: Error, Equatable {
    static let reason = "quit takes --keep-sessions or --end-sessions, not both"
}

/// The quit rules (user decision 2026-09-30), free of AppKit and the daemon.
enum QuitPolicy {
    static let busiestLimit = 3

    /// The origin of a `quit` action run: its flags, else scripted for a
    /// capturing caller (control socket, CLI), else interactive.
    static func origin(for invocation: ActionInvocation, scripted: Bool) throws(QuitArgumentConflict) -> QuitOrigin {
        let keep = invocation["keepSessions"]?.boolValue == true
        let end = invocation["endSessions"]?.boolValue == true
        switch (keep, end) {
        case (true, true): throw QuitArgumentConflict()
        case (true, false): return .explicit(.keep)
        case (false, true): return .explicit(.end)
        case (false, false): return scripted ? .scripted : .interactive
        }
    }

    /// Whether the decision needs `QuitFacts` (read from the daemon).
    static func needsFacts(_ origin: QuitOrigin) -> Bool { origin == .interactive }

    /// Quit at once with a choice, or ask. `facts` is read only for an
    /// interactive quit.
    static func decide(_ origin: QuitOrigin, behavior: QuitBehavior, facts: QuitFacts) -> QuitDecision {
        let remembered: QuitSessionsChoice? = switch behavior {
        case .ask: nil
        case .keep: .keep
        case .end: .end
        }
        switch origin {
        case .powerOff: return .quit(.keep)
        case .explicit(let choice): return .quit(choice)
        case .scripted: return .quit(remembered ?? .keep)
        case .interactive: break
        }
        let hasTerminals = facts.terminals > 0
        let incognito = !facts.incognitoPrograms.isEmpty
        guard hasTerminals || incognito else { return .quit(remembered ?? .keep) }
        // A remembered choice skips the sheet unless incognito windows would
        // end running programs (that confirmation is not remembered).
        if let remembered, !incognito { return .quit(remembered) }
        return .ask(QuitPrompt(
            terminals: facts.terminals,
            runningPrograms: facts.programs.count,
            busiest: busiest(facts.programs),
            incognitoPrograms: facts.incognitoPrograms,
            remoteSessions: facts.remoteSessions,
            offersSessionChoice: hasTerminals,
            defaultChoice: remembered ?? .keep
        ))
    }

    /// Unique program names, most CPU first (then by name), at most `limit`.
    static func busiest(_ programs: [QuitProgram], limit: Int = busiestLimit) -> [String] {
        var cpu: [String: UInt64] = [:]
        for program in programs { cpu[program.name, default: 0] += program.cpuNanos }
        return cpu.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(limit).map(\.key)
    }

    /// The setting "Don't ask again" writes for a choice.
    static func remembered(_ choice: QuitSessionsChoice) -> QuitBehavior {
        switch choice {
        case .keep: .keep
        case .end: .end
        }
    }
}
