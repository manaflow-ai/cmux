import CmuxNextCompat
import Foundation

/// The app's local acpmux daemon as Settings > Updates shows it: its build, and whether it is
/// the bundled build or restarting on it (``AcpmuxVersionHandoff``). Read when the card shows.
public nonisolated struct AcpmuxDaemonSummary: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case upToDate
        case restarting
        case notRunning
    }

    /// The running daemon's build, or the bundled one while a handoff starts it; nil when unknown.
    public var build: String?
    public var state: State

    /// Homes whose daemon a handoff stopped and whose bundled daemon has not started yet.
    private static let restartingHomes = Mutex<Set<String>>([])

    public init(build: String?, state: State) {
        self.build = build
        self.state = state
    }

    /// - Parameters:
    ///   - answered: the daemon answered `_acpmux/status` from this app's home.
    ///   - running: its build; nil when it does not say.
    ///   - bundled: the bundled acpmux's build; nil when unknown.
    ///   - restarting: a handoff stopped it and the bundled daemon is starting.
    /// A daemon of another build than the bundle's is restarted at the next lookup, so it is
    /// restarting too; a build either side does not know is taken as up to date.
    public init(answered: Bool, running: String?, bundled: String?, restarting: Bool) {
        if restarting {
            self.init(build: running ?? bundled, state: .restarting)
        } else if !answered {
            self.init(build: nil, state: .notRunning)
        } else if let running, let bundled, running != bundled {
            self.init(build: running, state: .restarting)
        } else {
            self.init(build: running ?? bundled, state: .upToDate)
        }
    }

    /// The row's title.
    public static var title: String {
        String(localized: "agentPane.acpmuxDaemon.title", defaultValue: "acpmux daemon", bundle: .module)
    }

    /// The row's value: "<build> (up to date)", "<build> (restarting…)" or "Not running".
    public var text: String {
        let build = build ?? "?"
        switch state {
        case .upToDate:
            return String(format: String(localized: "agentPane.acpmuxDaemon.upToDate", defaultValue: "%@ (up to date)",
                                         bundle: .module), build)
        case .restarting:
            return String(format: String(localized: "agentPane.acpmuxDaemon.restarting", defaultValue: "%@ (restarting…)",
                                         bundle: .module), build)
        case .notRunning:
            return String(localized: "agentPane.acpmuxDaemon.notRunning", defaultValue: "Not running", bundle: .module)
        }
    }

    /// Notes that a handoff stopped the daemon of `home` (standardized path), or that the lookup
    /// that started the bundled one settled.
    static func mark(home: String, restarting: Bool) {
        restartingHomes.withLock { homes in
            if restarting {
                _ = homes.insert(home)
            } else {
                _ = homes.remove(home)
            }
        }
    }

    /// The daemon of `environment` now; nil `environment` (no acpmux) is not running.
    @concurrent public static func current(_ environment: AcpmuxEnvironment?) async -> Self {
        guard let environment else { return Self(build: nil, state: .notRunning) }
        let restarting = restartingHomes.withLock { $0.contains(environment.home.standardizedFileURL.path) }
        let bundled = await AcpmuxVersionHandoff.bundledBuild(environment)
        let status = try? await AcpmuxStatusClient.status(socketPath: environment.socketPath)
        let answered = status?.serves(home: environment.home) ?? false
        return Self(answered: answered, running: answered ? status?.build : nil, bundled: bundled, restarting: restarting)
    }
}
