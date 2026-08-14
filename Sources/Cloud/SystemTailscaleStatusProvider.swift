import CMUXMobileCore
import CmuxFoundation
import Foundation

/// Reads the local Tailscale daemon's authenticated peer map through its CLI.
struct SystemTailscaleStatusProvider: TailscaleStatusProviding, Sendable {
    private static let executableCandidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
        "/opt/local/bin/tailscale",
    ]
    private static let commandTimeout: TimeInterval = 5

    private let commands: any CommandRunning
    private let executableOverride: String?

    init(
        commands: any CommandRunning = CommandRunner(),
        executableOverride: String? = nil
    ) {
        self.commands = commands
        self.executableOverride = executableOverride
    }

    func statusJSON() async throws -> Data {
        let executable: String
        if let executableOverride {
            executable = executableOverride
        } else {
            guard let installed = Self.executableCandidates.first(where: {
                FileManager.default.isExecutableFile(atPath: $0)
            }) else {
                throw SystemTailscaleStatusProviderError.statusUnavailable
            }
            executable = installed
        }
        let result = await commands.run(
            directory: "/",
            executable: executable,
            arguments: ["status", "--json"],
            timeout: Self.commandTimeout
        )
        guard result.executionError == nil,
              !result.timedOut,
              result.exitStatus == 0,
              let stdout = result.stdout,
              let data = stdout.data(using: .utf8),
              !data.isEmpty,
              data.count <= CmxTailscaleStatusPeerResolver.maximumStatusBytes else {
            throw SystemTailscaleStatusProviderError.statusUnavailable
        }
        return data
    }
}
