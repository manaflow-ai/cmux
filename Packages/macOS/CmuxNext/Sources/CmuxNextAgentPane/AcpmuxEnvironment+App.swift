public import CmuxNextCompat
public import Foundation

/// The acpmux this app runs, resolved from the app's build: what `QuitAgents.environment` returns.
nonisolated extension AcpmuxEnvironment {
    /// The acpmux this app starts (its build's home), or nil when the app runs a mock agent host
    /// (`mock`, or `CMUX_NEXT_AGENT_PANE_MOCK=1`) or has no acpmux binary. A DEV build with
    /// `CMUX_NEXT_ACPMUX_ATTACH` gets that home's daemon instead, attached (never its own).
    /// It searches paths and checks the executable's signature on the calling thread: a reader on
    /// a path that must not wait (the Dock menu) uses ``resolvedApp(build:mock:)``.
    public static func app(build: BuildIdentity?, mock: Bool,
                           environment variables: [String: String] = ProcessInfo.processInfo.environment) -> AcpmuxEnvironment? {
        if mock || variables["CMUX_NEXT_AGENT_PANE_MOCK"] == "1" { return nil }
        let bin = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true)
        let own = resolve(build: build, bundledBinDirectory: bin, environment: variables)
        guard let home = attachHome(build: build, environment: variables) else { return own }
        return own?.attached(to: home)
    }

    /// ``app(build:mock:environment:)`` off the caller's actor, so the main thread never does its
    /// path search and signature check (#33728).
    @concurrent public static func resolvedApp(build: BuildIdentity?, mock: Bool) async -> AcpmuxEnvironment? {
        app(build: build, mock: mock)
    }
}
