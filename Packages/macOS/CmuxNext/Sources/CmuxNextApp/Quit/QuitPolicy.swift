import CmuxNextActions
import CmuxNextSettings

/// A quit request that names more than one choice.
struct QuitArgumentConflict: Error, Equatable {
    static let reason = "quit takes one of --keep-sessions, --end-sessions and --end-everything"
}

/// The quit rules (user decision 2026-09-30), free of AppKit and the daemon.
enum QuitPolicy {
    static let busiestLimit = 3

    /// The origin of a `quit` action run: its flags, else scripted for a
    /// capturing caller (control socket, CLI), else interactive.
    static func origin(for invocation: ActionInvocation, scripted: Bool) throws(QuitArgumentConflict) -> QuitOrigin {
        let flags: [(String, QuitSessionsChoice)] = [("keepSessions", .keep), ("endSessions", .endKeepLayout), ("endEverything", .endEverything)]
        let chosen = flags.filter { invocation[$0.0]?.boolValue == true }.map(\.1)
        guard chosen.count <= 1 else { throw QuitArgumentConflict() }
        if let choice = chosen.first { return .explicit(choice) }
        return scripted ? .scripted : .interactive
    }

    /// Whether the decision needs `QuitFacts` (read from the daemon).
    static func needsFacts(_ origin: QuitOrigin) -> Bool { origin == .interactive }

    /// Quit at once with a choice, or ask. `facts` is read only for an
    /// interactive quit. Keep, the default choice, loses no work, because
    /// local terminals and agents run in their daemons and reattach on the
    /// next launch; a remembered end choice applies as set. `confirm`
    /// (`app.confirmQuit`, classic's key) asks "Quit cmux?" before an
    /// interactive quit: "always" (the default, as in classic, #25567), or
    /// "dirty-only" while a program runs or an agent is in a turn; "never"
    /// quits at once (Lawrence 2026-10-07). Otherwise the one question left is
    /// incognito windows' running programs, which end with the windows and
    /// cannot come back. Either is asked at most once (#17501): never after
    /// the unsaved-changes question (`alreadyAsked`).
    static func decide(_ origin: QuitOrigin, behavior: QuitBehavior, confirm: ConfirmQuitMode = ConfirmQuitMode.fallback,
                       facts: QuitFacts, alreadyAsked: Bool = false) -> QuitDecision {
        let remembered: QuitSessionsChoice? = switch behavior {
        case .ask: nil
        case .keep: .keep
        case .endKeepLayout: .endKeepLayout
        case .endEverything: .endEverything
        }
        switch origin {
        // Power off and SIGTERM never ask and never end terminals.
        case .powerOff, .signal: return .quit(.keep)
        case .explicit(let choice): return .quit(choice)
        case .scripted: return .quit(remembered ?? .keep)
        case .interactive: break
        }
        let confirms = switch confirm {
        case .always: true
        case .dirtyOnly: !facts.programs.isEmpty || (facts.agents?.inTurn ?? 0) > 0
        case .never: false
        }
        guard !alreadyAsked, confirms || !facts.incognitoPrograms.isEmpty else { return .quit(remembered ?? .keep) }
        // "Quit cmux?" when confirming, else the incognito close confirmation:
        // Quit applies the remembered choice (else Keep).
        return .ask(QuitPrompt(
            terminals: facts.terminals,
            runningPrograms: facts.programs.count,
            busiest: busiest(facts.programs),
            incognitoPrograms: facts.incognitoPrograms,
            remoteSessions: facts.remoteSessions,
            // With a remembered choice the dialog only confirms it (Quit and Cancel).
            offersSessionChoice: confirms && remembered == nil,
            defaultChoice: remembered ?? .keep,
            agents: facts.agents?.live,
            agentsInTurn: facts.agents?.inTurn ?? 0,
            busyAgents: Array((facts.agents?.inTurnNames ?? []).prefix(busiestLimit)),
            chiefKeepsRunning: facts.agents?.chiefInTurn ?? false
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
        case .endKeepLayout: .endKeepLayout
        case .endEverything: .endEverything
        }
    }
}
