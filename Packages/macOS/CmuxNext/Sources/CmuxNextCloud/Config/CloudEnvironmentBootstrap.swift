import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextWakeups
import Foundation

/// Thin process adapter: Rust resolves and validates the selected environment before app services start.
public struct CloudEnvironmentBootstrap {
    let work: BackgroundWork

    public init(work: BackgroundWork) { self.work = work }

    public func resolve() async throws -> CloudRuntimeSelection {
        guard let cli = await BundledExecutable.cli(resources: Bundle.main.resourceURL, work: work).resolve() else {
            throw DaemonError.launchFailed("The bundled cmux CLI is unavailable.")
        }
        var environment = ProcessInfo.processInfo.environment
        // A source CLI override still resolves the actual app's namespace.
        if let bundleID = Bundle.main.bundleIdentifier { environment["CMUX_BUNDLE_ID"] = bundleID }
        let result = try await ProcessRunner.run(executable: cli, arguments: ["--json", "cloud", "env", "get"],
            environment: environment, timeout: nil, clock: ContinuousClock())
        guard result.status == 0 else {
            throw DaemonError.launchFailed("Could not resolve this app's Cloud environment: " + String(decoding: result.stderr, as: UTF8.self))
        }
        let selection = try CloudRuntimeSelection.decode(result.stdout)
        guard selection.bundleId == Bundle.main.bundleIdentifier else {
            throw DaemonError.launchFailed("The Cloud environment belongs to another app bundle.")
        }
        return selection
    }
    public func startRelaunch() async throws -> Int32 {
        guard let cli = await BundledExecutable.cli(resources: Bundle.main.resourceURL, work: work).resolve() else {
            throw DaemonError.launchFailed("The bundled cmux CLI is unavailable.")
        }
        let appPID = ProcessInfo.processInfo.processIdentifier
        let bundlePath = Bundle.main.bundleURL.path
        return try await work.run(.userVisible, mayBlock: .system) {
            let process = Process()
            process.executableURL = cli
            process.arguments = ["cloud", "env", "relaunch", "--pid", String(appPID), "--bundle-path", bundlePath]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            return process.processIdentifier
        }
    }
}
