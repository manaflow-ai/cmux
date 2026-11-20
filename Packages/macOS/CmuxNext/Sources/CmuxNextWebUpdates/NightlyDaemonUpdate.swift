import CmuxNextSettings
import Foundation

/// The app's setting starts one bundled Rust worker. It checks the setting again
/// after staging the signed binaries and before touching the running daemon.
@MainActor
public final class NightlyDaemonUpdate {
    public var quiet: @MainActor () async -> Bool = { false }
    private var worker: Process?
    private var enabled = false

    public static func available(in bundle: Bundle = .main) -> Bool {
        #if DEBUG
        false
        #else
        WebUpdates.isAvailable(bundle)
        #endif
    }

    func follow(_ requested: Bool, bundle: Bundle) {
        enabled = requested && Self.available(in: bundle)
        guard enabled, worker?.isRunning != true, let resources = bundle.resourceURL else { return }
        let process = Process()
        process.executableURL = resources.appending(path: "bin/cmux", directoryHint: .notDirectory)
        process.arguments = ["app", "try", "follow-channel", "--app", bundle.bundlePath]
        do {
            try process.run()
            worker = process
        } catch {
            NSLog("NIGHTLY daemon updater: %@", error.localizedDescription)
        }
    }

    func readiness(checkActivity: Bool) async -> JSONValue {
        let ready: Bool
        if enabled && checkActivity { ready = await quiet() } else { ready = false }
        return .object(["enabled": .bool(enabled), "quiet": .bool(enabled && ready)])
    }
}
