@testable import CmuxNextAgentIntegrations
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// #54632: opening Settings trapped in `rows` on a cooperative thread. The page's refresh awaits
/// the app's own CLI runner (a real process), then reads the rows through main-actor key paths;
/// that read, and every state write after it, must be back on the main thread.
@MainActor struct SettingsAgentIntegrationsExecutorTests {
    nonisolated final class Seen: @unchecked Sendable { var mainThread: [Bool] = [] }

    /// Records the thread of every change to the model's state (re-armed after each one).
    nonisolated static func track(_ model: SettingsAgentIntegrations, _ seen: Seen) {
        MainActor.assumeIsolated {
            withObservationTracking { _ = model.state } onChange: {
                seen.mainThread.append(Thread.isMainThread)
                guard Thread.isMainThread else { return }
                Task { @MainActor in track(model, seen) }
            }
        }
    }

    /// A stand-in for the bundled CLI: a shell script that prints the status answer.
    static func scriptCLI() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-54632-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("cmux")
        let body = "#!/bin/sh\ncat <<'CMUX_STATUS'\n\(SettingsAgentIntegrationsTests.status)\nCMUX_STATUS\n"
        try Data(body.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func refreshThroughTheAppsRunnerWritesTheRowsOnTheMainThread() async throws {
        let cli = try Self.scriptCLI()
        defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }
        // The app's wiring: no runCLI, so the default (the real process runner) runs.
        let model = SettingsAgentIntegrations(cli: { cli })
        let provider: any PageProvider = model
        let seen = Seen()
        Self.track(model, seen)
        _ = try await provider.call("cmux.settings.integrations.run", params: ["action": "refresh"],
                                    context: SettingsAgentIntegrationsTests.script)
        #expect(!seen.mainThread.isEmpty, "refresh changed nothing")
        #expect(seen.mainThread.allSatisfy { $0 }, "refresh wrote its state off the main thread")
        #expect(model.state["providers"]?.arrayValue?.count == 5)
        #expect(model.state["problem"] == .null)
    }
}
