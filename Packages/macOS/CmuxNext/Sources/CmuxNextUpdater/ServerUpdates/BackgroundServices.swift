public import CmuxNextDesign
import Foundation

/// One background service this app runs from its bundled binaries, as Restart Background
/// Services… shows it (cmux issue 23089): the build that runs and the build this app bundles.
public nonisolated struct BackgroundService: Sendable, Equatable, Identifiable {
    /// Which service.
    public enum Role: String, Sendable, CaseIterable {
        /// This app's cmux-tui session owner: terminals, workspaces and layouts.
        case sessionOwner
        /// The Chief home's cmux-tui owner: Home's conversations.
        case chiefOwner
        /// This app's acpmux: agent chats.
        case agents
        /// The Chief home's acpmux: the Chief and its subagents.
        case chiefAgents
    }

    public var role: Role
    /// The running build; nil when the service does not run.
    public var running: String?
    /// The bundled build; nil when it could not be read.
    public var bundled: String?
    /// Why the restart leaves this running service as it is; nil when it restarts it.
    public var skip: Skip?

    /// Why a running service is not restarted.
    public enum Skip: Sendable, Equatable {
        /// An acpmux without agent hosts: a restart would end its agents.
        case endsAgents
        /// The Chief's acpmux with no Chief host running: only that host starts the next one.
        case restartsWithChief
    }

    public init(role: Role, running: String?, bundled: String?, skip: Skip? = nil) {
        self.role = role
        self.running = running
        self.bundled = bundled
        self.skip = skip
    }

    /// The restart restarts this service: it runs and nothing keeps it.
    public var restarts: Bool { running != nil && skip == nil }

    public var id: String { role.rawValue }

    /// The service as the person reads it; the product names are never localized.
    public var title: String {
        switch role {
        case .sessionOwner: UpdaterStrings.text("services.title.sessionOwner", "Terminals (cmux-tui)")
        case .chiefOwner: UpdaterStrings.text("services.title.chiefOwner", "Chief conversations (cmux-tui)")
        case .agents: UpdaterStrings.text("services.title.agents", "Agents (acpmux)")
        case .chiefAgents: UpdaterStrings.text("services.title.chiefAgents", "Chief agents (acpmux)")
        }
    }

    /// The running build is the bundled one.
    public var isCurrent: Bool {
        guard let running, let bundled else { return false }
        return running == bundled
    }

    /// A build as the dialog shows it: its commit, without the date acpmux adds.
    public static func shortBuild(_ build: String) -> String {
        String(build.split(separator: " ").first.map(String.init)?.prefix(9) ?? Substring(build))
    }

    /// The dialog line: running vs bundled build, and what the restart does with it.
    public var line: String {
        let bundledText = bundled.map(Self.shortBuild) ?? UpdaterStrings.text("services.build.unknown", "unknown")
        guard let running else {
            return UpdaterStrings.format("services.line.notRunning", "%1$@: not running (bundled %2$@).", title, bundledText)
        }
        let runningText = Self.shortBuild(running)
        switch skip {
        case .endsAgents:
            return UpdaterStrings.format("services.line.kept", "%1$@: %2$@ (bundled %3$@). Kept running: a restart would end its agents.",
                                         title, runningText, bundledText)
        case .restartsWithChief:
            return UpdaterStrings.format("services.line.keptNoHost",
                                         "%1$@: %2$@ (bundled %3$@). Kept running: it restarts with the Chief.",
                                         title, runningText, bundledText)
        case nil:
            break
        }
        if isCurrent {
            return UpdaterStrings.format("services.line.current", "%1$@: %2$@, the bundled build.", title, runningText)
        }
        return UpdaterStrings.format("services.line.stale", "%1$@: %2$@; this app bundles %3$@.", title, runningText, bundledText)
    }
}

/// Every background service of this app, for the Restart Background Services… confirm.
public nonisolated struct BackgroundServicesReport: Sendable, Equatable {
    public var services: [BackgroundService]

    public init(services: [BackgroundService]) {
        self.services = services
    }

    /// The confirm: each service's running and bundled build, what is kept, Cancel and Restart.
    public var confirmSpec: CmuxDialogSpec {
        let restart = CmuxDialogButton(id: "restart", title: UpdaterStrings.text("server.confirm.restart", "Restart"), role: .default)
        // The same kept and lost lines as a single server's restart (ServerRestartImpact), for
        // the kinds of server this restart restarts.
        let restarting = services.filter(\.restarts).map(\.role)
        let impacts = [
            restarting.contains { $0 == .sessionOwner || $0 == .chiefOwner } ? ServerRestartImpact(kind: .cmuxTUI, keepsWork: true) : nil,
            restarting.contains { $0 == .agents || $0 == .chiefAgents } ? ServerRestartImpact(kind: .acpmux, keepsWork: true) : nil,
        ].compactMap { $0 }
        return CmuxDialogSpec(title: UpdaterStrings.text("services.confirm.title", "Restart Background Services?"),
                              lines: services.map(\.line) + impacts.flatMap(\.kept) + impacts.flatMap(\.lost),
                              buttons: [.cancel(), restart],
                              identifier: "cmux.background-services-restart")
    }
}

/// What Restart Background Services… did, for its result toast.
public nonisolated struct BackgroundServicesRestartResult: Sendable, Equatable {
    /// Services that restarted on the bundled build.
    public var restarted: [BackgroundService.Role]
    /// Services that restart once the Chief's turn in progress ends.
    public var afterTurn: [BackgroundService.Role]
    /// Services that failed, with the reason.
    public var failed: [Failure]

    public struct Failure: Sendable, Equatable {
        public var role: BackgroundService.Role
        public var reason: Reason

        /// Why a service did not restart.
        public enum Reason: Sendable, Equatable {
            /// It refused the handoff, or did not answer it.
            case refused
            /// It stopped, but its successor did not come back in time.
            case didNotReturn
            /// Another error, as the process reported it.
            case other(String)

            var text: String {
                switch self {
                case .refused: UpdaterStrings.text("services.reason.refused", "it refused to stop")
                case .didNotReturn: UpdaterStrings.text("services.reason.didNotReturn", "it didn't come back in time")
                case .other(let detail): detail
                }
            }
        }

        public init(role: BackgroundService.Role, reason: Reason) {
            self.role = role
            self.reason = reason
        }
    }

    public init(restarted: [BackgroundService.Role] = [], afterTurn: [BackgroundService.Role] = [], failed: [Failure] = []) {
        self.restarted = restarted
        self.afterTurn = afterTurn
        self.failed = failed
    }

    /// The toast after the restart.
    public var message: String {
        if let first = failed.first {
            let name = BackgroundService(role: first.role, running: nil, bundled: nil).title
            return UpdaterStrings.format("server.result.failed", "Couldn't restart %1$@: %2$@", name, first.reason.text)
        }
        if !afterTurn.isEmpty {
            return UpdaterStrings.text("services.result.afterTurn",
                                       "Background services restarted. The Chief's restarts when its turn ends.")
        }
        return UpdaterStrings.text("services.result.restarted", "Background services restarted on the bundled build.")
    }
}
