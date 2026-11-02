/// The quit rules (user decision 2026-09-30), free of AppKit and the
/// settings: what the quit decision reads, what the quit dialog shows, and
/// the decision. The App maps `app.quitBehavior` to the remembered choice
/// (`QuitPolicy`) and runs the quit (`QuitCoordinator`).

public struct QuitRules {
    public init() {}
    public static let busiestLimit = 3

    /// Whether the decision needs `QuitFacts` (read from the daemon).
    public static func needsFacts(_ origin: QuitOrigin) -> Bool { origin == .interactive }

    /// Quit at once with a choice, or ask. `remembered` is the setting's
    /// choice (nil for Ask). `facts` is read only for an interactive quit.
    /// A person's quit (Cmd-Q, the menu, the Dock) with local terminals and
    /// Ask asks how to quit (QUIT P0, Lawrence 2026-11-01: "cmd q needs to
    /// prompt for what type of quit"; this takes back the 2026-10-07 "no
    /// Quit cmux?"): Keep Sessions Running (the default), End Sessions, Keep
    /// Layout, End Everything, or Cancel. A remembered choice applies as
    /// set, except End Everything, which asks first (it deletes every
    /// workspace). With no local terminal there is nothing to choose. The
    /// incognito close confirmation (their programs end with their windows)
    /// folds into the same question, or is the only one when a remembered
    /// choice applies. A quit asks at most once (#17501): never after the
    /// unsaved-changes question (`alreadyAsked`).
    public static func decide(_ origin: QuitOrigin, remembered: QuitSessionsChoice?, facts: QuitFacts,
                              alreadyAsked: Bool = false) -> QuitDecision {
        switch origin {
        // Power off and SIGTERM never ask and never end terminals.
        case .powerOff, .signal: return .quit(.keep)
        case .explicit(let choice): return .quit(choice)
        case .scripted: return .quit(unattended(remembered) ?? .keep)
        case .interactive: break
        }
        if remembered == .endEverything {
            // Deleting every workspace is never a single keystroke: ask, and
            // after the unsaved-changes question (one dialog per quit) end the
            // sessions but keep the workspaces.
            guard !alreadyAsked else { return .quit(.endKeepLayout) }
            return .ask(prompt(facts, offersSessionChoice: true, defaultChoice: .keep, confirmsEndEverything: true))
        }
        let offersSessionChoice = remembered == nil && facts.terminals > 0
        guard !alreadyAsked, offersSessionChoice || !facts.incognitoPrograms.isEmpty else { return .quit(remembered ?? .keep) }
        // The session choice, or (a remembered choice) the incognito close confirmation: Quit applies it.
        return .ask(prompt(facts, offersSessionChoice: offersSessionChoice, defaultChoice: remembered ?? .keep,
                           confirmsEndEverything: false))
    }

    /// A remembered choice for a quit that cannot ask (`cmux app quit` with
    /// no flag): End Everything ends the sessions but keeps the workspaces;
    /// only `--end-everything` or the File menu item deletes them.
    public static func unattended(_ remembered: QuitSessionsChoice?) -> QuitSessionsChoice? {
        remembered == .endEverything ? .endKeepLayout : remembered
    }

    /// Unique program names, most CPU first (then by name), at most `limit`.
    public static func busiest(_ programs: [QuitProgram], limit: Int = busiestLimit) -> [String] {
        var cpu: [String: UInt64] = [:]
        for program in programs { cpu[program.name, default: 0] += program.cpuNanos }
        return cpu.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(limit).map(\.key)
    }

    private static func prompt(_ facts: QuitFacts, offersSessionChoice: Bool, defaultChoice: QuitSessionsChoice,
                               confirmsEndEverything: Bool) -> QuitPrompt {
        QuitPrompt(
            terminals: facts.terminals,
            runningPrograms: facts.programs.count,
            busiest: busiest(facts.programs),
            incognitoPrograms: facts.incognitoPrograms,
            remoteSessions: facts.remoteSessions,
            offersSessionChoice: offersSessionChoice,
            defaultChoice: defaultChoice,
            confirmsEndEverything: confirmsEndEverything,
            agents: facts.agents?.live,
            agentsInTurn: facts.agents?.inTurn ?? 0,
            busyAgents: Array((facts.agents?.inTurnNames ?? []).prefix(busiestLimit)),
            chiefKeepsRunning: facts.agents?.chiefInTurn ?? false
        )
    }
}
