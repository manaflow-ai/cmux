import CmuxNextCompat
import Foundation

/// The app's local acpmux daemon as Settings > Updates shows it (the Channels card's daemon
/// line): its build, and whether it is the bundled build, restarting on it
/// (``AcpmuxVersionHandoff``), or another build the app keeps. Read once when the card shows,
/// never polled.
public nonisolated struct AcpmuxDaemonSummary: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case upToDate
        case restarting
        /// Another build than the bundle's that no lookup hands off: a memory store without agent
        /// hosts, an attached daemon, or one this launch's handoff could not stop.
        case otherBuild
        case notRunning
    }

    /// The running daemon's build, or the bundled one while a handoff starts it; nil when unknown.
    public var build: String?
    public var state: State

    /// Homes (standardized paths) whose daemon a handoff is stopping, until the lookup that
    /// starts the bundled one settles.
    private static let restartingHomes = Mutex<Set<String>>([])

    public init(build: String?, state: State) {
        self.build = build
        self.state = state
    }

    /// - Parameters:
    ///   - answered: the daemon answered `_acpmux/status` from this app's home.
    ///   - running: its build; nil when it does not say.
    ///   - bundled: the bundled acpmux's build; nil when unknown.
    ///   - restarting: a handoff is stopping it, or the bundled daemon is starting.
    ///   - replaced: it runs another executable than the app's: a bundle an update replaced, or
    ///     a stray `~/.local/bin/acpmux` (``AcpmuxStrayDaemon``).
    ///   - handsOff: a lookup would hand it off or take it over
    ///     (``AcpmuxVersionHandoff/handsOff(_:environment:bundled:)``, ``AcpmuxStrayDaemon/takesOver(_:environment:)``).
    /// A daemon of another build than the bundle's, a replaced bundle's or a stray one is
    /// restarted at the next lookup, so it is restarting too unless no lookup hands it off; a
    /// build either side does not know is taken as up to date.
    public init(answered: Bool, running: String?, bundled: String?, restarting: Bool,
                replaced: Bool = false, handsOff: Bool = true) {
        let stale = if let running, let bundled { running != bundled } else { false }
        if restarting {
            self.init(build: running ?? bundled, state: .restarting)
        } else if !answered {
            self.init(build: nil, state: .notRunning)
        } else if stale || replaced {
            self.init(build: running ?? bundled, state: handsOff ? .restarting : .otherBuild)
        } else {
            self.init(build: running ?? bundled, state: .upToDate)
        }
    }

    /// The row's title.
    public static var title: String {
        String(localized: "agentPane.acpmuxDaemon.title", defaultValue: "acpmux daemon", bundle: .module)
    }

    /// The row's value: "<build> (up to date)", "<build> (restarting…)", "<build> (not the app's
    /// build)" or "Not running".
    public var text: String {
        let build = build ?? "?"
        switch state {
        case .upToDate:
            return String(format: String(localized: "agentPane.acpmuxDaemon.upToDate", defaultValue: "%@ (up to date)",
                                         bundle: .module), build)
        case .restarting:
            return String(format: String(localized: "agentPane.acpmuxDaemon.restarting", defaultValue: "%@ (restarting…)",
                                         bundle: .module), build)
        case .otherBuild:
            return String(format: String(localized: "agentPane.acpmuxDaemon.otherBuild", defaultValue: "%@ (not the app's build)",
                                         bundle: .module), build)
        case .notRunning:
            return String(localized: "agentPane.acpmuxDaemon.notRunning", defaultValue: "Not running", bundle: .module)
        }
    }

    /// Notes that a handoff is stopping the daemon of `home`, or that it settled: its shutdown
    /// failed, the old daemon did not exit, or the lookup that starts the bundled one ended.
    static func mark(home: URL, restarting: Bool) {
        let path = home.standardizedFileURL.path
        restartingHomes.withLock { homes in
            if restarting {
                _ = homes.insert(path)
            } else {
                _ = homes.remove(path)
            }
        }
    }

    static func isRestarting(home: URL) -> Bool {
        let path = home.standardizedFileURL.path
        return restartingHomes.withLock { $0.contains(path) }
    }

    /// How long the bundled acpmux may take to say its build: the card waits for this line.
    static let versionBound: Duration = .seconds(2)

    /// The daemon of `environment` now: one `--version` call (bounded, ``versionBound``) and one
    /// `_acpmux/status` call (2 s), so the card waits at most about 4 s. A nil `environment` (no
    /// acpmux) is not running.
    @concurrent public static func current(_ environment: AcpmuxEnvironment?) async -> Self {
        guard let environment else { return Self(build: nil, state: .notRunning) }
        let bundled = await DaemonUpdatePolicy.bundledBuild(of: environment.executable, within: versionBound)
        let status = try? await AcpmuxStatusClient.status(socketPath: environment.socketPath)
        guard let status, status.serves(home: environment.home) else {
            return Self(answered: false, running: nil, bundled: bundled, restarting: isRestarting(home: environment.home))
        }
        // What a lookup would do first, then the mark: a handoff uses its key and sets the mark in
        // one step, so a used key read here comes with its mark unless that handoff settled since
        // (a failure clears it: the daemon it kept is not the app's build). Both after the awaits.
        let stray = AcpmuxStrayDaemon.takesOver(status, environment: environment)
        let handoff = AcpmuxVersionHandoff.handsOff(status, environment: environment, bundled: bundled)
        let restarting = isRestarting(home: environment.home)
        return Self(answered: true, running: status.build, bundled: bundled, restarting: restarting,
                    replaced: handoff.replaced || stray.stray, handsOff: stray.takesOver || handoff.handsOff)
    }
}
