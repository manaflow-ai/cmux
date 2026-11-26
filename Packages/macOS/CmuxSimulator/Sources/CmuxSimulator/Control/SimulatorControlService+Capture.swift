import Foundation

extension SimulatorControlService {
    /// Saves a screenshot to a file URL.
    public func screenshot(
        deviceID: String,
        destinationURL: URL,
        format: SimulatorScreenshotFormat = .png
    ) async throws {
        _ = try await output(arguments: [
            "simctl", "io", deviceID, "screenshot", "--type=\(format.rawValue)",
            destinationURL.path,
        ])
    }

    /// Creates the long-running command for a video recording.
    public nonisolated func videoRecordingCommand(
        deviceID: String,
        destinationURL: URL,
        codec: SimulatorVideoCodec = .hevc
    ) -> SimulatorCommandDescriptor {
        SimulatorCommandDescriptor(
            executable: "/usr/bin/xcrun",
            arguments: [
                "simctl", "io", deviceID, "recordVideo", "--codec=\(codec.rawValue)",
                "--force", destinationURL.path,
            ]
        )
    }

    /// Returns a bounded slice from the simulated unified log.
    public func recentLogs(
        deviceID: String,
        bundleIdentifier: String? = nil,
        seconds: Double = 60
    ) async throws -> String {
        guard seconds.isFinite, seconds > 0 else {
            throw SimulatorControlError(
                code: "invalid_log_interval",
                arguments: ["simctl", "spawn", deviceID, "log", "show"],
                message: String(
                    localized: "simulator.control.logIntervalInvalid",
                    defaultValue: "The log interval must be positive."
                )
            )
        }
        var arguments = [
            "simctl", "spawn", deviceID, "log", "show", "--style", "compact",
            "--last", "\(seconds)s",
        ]
        if let bundleIdentifier {
            arguments += ["--predicate", "subsystem == \"\(bundleIdentifier)\""]
        }
        let result = try await boundedOutput(
            arguments: arguments,
            standardOutputLimit: Self.maximumRecentLogBytes
        )
        var logs = String(decoding: result.standardOutput, as: UTF8.self)
        if result.outputWasTruncated {
            let marker = String(
                localized: "simulator.logs.outputTruncated",
                defaultValue: "Output truncated at 2 MiB."
            )
            logs += "\n[\(marker)]\n"
        }
        return logs
    }

    /// Creates the long-running command for a live unified-log stream.
    public nonisolated func logStreamCommand(
        deviceID: String,
        bundleIdentifier: String? = nil
    ) -> SimulatorCommandDescriptor {
        var arguments = [
            "simctl", "spawn", deviceID, "log", "stream", "--style", "compact",
        ]
        if let bundleIdentifier {
            arguments += ["--predicate", "subsystem == \"\(bundleIdentifier)\""]
        }
        return SimulatorCommandDescriptor(executable: "/usr/bin/xcrun", arguments: arguments)
    }

    /// Performs one typed native-tools action.
}
