/// The quit rules (user decision 2026-09-30), free of AppKit and the
/// settings: what the quit decision reads, what the quit dialog shows, and
/// the decision. The App maps `app.quitBehavior` to the remembered choice
/// (`QuitPolicy`) and runs the quit (`QuitCoordinator`).

/// One running program in a terminal that Quit keeps.
public struct QuitProgram: Equatable, Sendable {
    public var name: String
    /// CPU time of the terminal's processes other than its shell.
    public var cpuNanos: UInt64

    public init(name: String, cpuNanos: UInt64) {
        self.name = name
        self.cpuNanos = cpuNanos
    }
}

/// The local acpmux daemon's agent sessions, read for an interactive quit.
public struct QuitAgentFacts: Equatable, Sendable {
    /// Sessions with a running agent process (ready, running or waiting).
    public var live: Int
    /// Sessions in a turn (running, or waiting for a permission answer).
    public var inTurn: Int
    /// Titles (else names) of the sessions in a turn, at most `QuitRules.busiestLimit`.
    public var inTurnNames: [String]
    /// The Home Chief is in a turn. The Chief is never counted above and
    /// never ended by a quit; the dialog says it keeps running.
    public var chiefInTurn: Bool

    public init(live: Int, inTurn: Int, inTurnNames: [String], chiefInTurn: Bool = false) {
        self.live = live
        self.inTurn = inTurn
        self.inTurnNames = inTurnNames
        self.chiefInTurn = chiefInTurn
    }

    public static let zero = QuitAgentFacts(live: 0, inTurn: 0, inTurnNames: [])
}

/// The local state the quit decision reads.
public struct QuitFacts: Equatable, Sendable {
    /// Local terminals outside incognito windows (they outlive the app).
    public var terminals: Int
    /// Those terminals' foreground programs other than the shell.
    public var programs: [QuitProgram]
    /// Programs running in incognito windows' terminals, which always end.
    public var incognitoPrograms: [String]
    /// Any Cloud or SSH session is known (never ended from the sheet).
    public var remoteSessions: Bool
    /// The local acpmux daemon's agents (they outlive the app too). Nil when
    /// acpmux has a socket but did not answer in time: unknown, not zero.
    public var agents: QuitAgentFacts?

    public init(terminals: Int, programs: [QuitProgram], incognitoPrograms: [String], remoteSessions: Bool,
                agents: QuitAgentFacts? = .zero) {
        self.terminals = terminals
        self.programs = programs
        self.incognitoPrograms = incognitoPrograms
        self.remoteSessions = remoteSessions
        self.agents = agents
    }

    public static let none = QuitFacts(terminals: 0, programs: [], incognitoPrograms: [], remoteSessions: false)
}

/// The quit alert's content.
public struct QuitPrompt: Equatable, Sendable {
    public var terminals: Int
    public var runningPrograms: Int
    /// The busiest program names (most CPU first), at most `QuitRules.busiestLimit`.
    public var busiest: [String]
    public var incognitoPrograms: [String]
    public var remoteSessions: Bool
    /// False when only incognito terminals are at stake, or a remembered
    /// end applies: the alert then only confirms the incognito close (Quit
    /// and Cancel).
    public var offersSessionChoice: Bool
    /// The button Return presses.
    public var defaultChoice: QuitSessionsChoice
    /// A remembered End Everything asks before it deletes the workspaces:
    /// Keep Sessions Running (Return), Cancel (Escape), End Everything (no
    /// key). A Cmd-Q typed by mistake never closes every workspace
    /// (2026-10-31: 900 closed with no dialog).
    public var confirmsEndEverything: Bool
    /// Live local agents that keep running; nil when acpmux did not answer.
    public var agents: Int?
    /// Local agents in a turn now.
    public var agentsInTurn: Int
    /// Their titles, at most `QuitRules.busiestLimit`.
    public var busyAgents: [String]
    /// The Home Chief is in a turn: one line "Chief keeps running".
    public var chiefKeepsRunning: Bool

    public init(terminals: Int, runningPrograms: Int, busiest: [String], incognitoPrograms: [String], remoteSessions: Bool,
                offersSessionChoice: Bool, defaultChoice: QuitSessionsChoice, confirmsEndEverything: Bool = false,
                agents: Int? = 0, agentsInTurn: Int = 0, busyAgents: [String] = [], chiefKeepsRunning: Bool = false) {
        self.terminals = terminals
        self.runningPrograms = runningPrograms
        self.busiest = busiest
        self.incognitoPrograms = incognitoPrograms
        self.remoteSessions = remoteSessions
        self.offersSessionChoice = offersSessionChoice
        self.defaultChoice = defaultChoice
        self.confirmsEndEverything = confirmsEndEverything
        self.agents = agents
        self.agentsInTurn = agentsInTurn
        self.busyAgents = busyAgents
        self.chiefKeepsRunning = chiefKeepsRunning
    }
}

public enum QuitDecision: Equatable, Sendable {
    case quit(QuitSessionsChoice)
    case ask(QuitPrompt)
}

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
