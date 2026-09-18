import Foundation

struct AgentSessionLaunchPlan: Equatable, Sendable {
    let provider: AgentSessionProviderID
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]

    func environment(overridingWorkingDirectory workingDirectory: String?) -> [String: String] {
        var launchEnvironment = environment
        if provider == .opencode,
           launchEnvironment["OPENCODE_SERVER_PASSWORD"]?.isEmpty != false {
            launchEnvironment["OPENCODE_SERVER_USERNAME"] = launchEnvironment["OPENCODE_SERVER_USERNAME"].flatMap { value in
                value.isEmpty ? nil : value
            } ?? "opencode"
            launchEnvironment["OPENCODE_SERVER_PASSWORD"] = "\(UUID().uuidString)-\(UUID().uuidString)"
        }
        if let workingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !workingDirectory.isEmpty {
            launchEnvironment["PWD"] = URL(fileURLWithPath: workingDirectory, isDirectory: true)
                .standardizedFileURL
                .path
        }
        return Self.withCmuxRuntimeEnvironment(launchEnvironment)
    }

    /// Pins agent child processes to the cmux instance that launched them.
    /// This lets a Codex session invoke the bundled `cmux` CLI without falling
    /// back to a stale default socket or a different installed app.
    static func withCmuxRuntimeEnvironment(
        _ environment: [String: String],
        resourceURL: URL? = Bundle.main.resourceURL
    ) -> [String: String] {
        var launchEnvironment = environment
        if let socketPath = launchEnvironment["CMUX_SOCKET_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !socketPath.isEmpty {
            launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
            launchEnvironment.removeValue(forKey: "CMUX_SOCKET")
            launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        }
        if let bundleIdentifier = Bundle.main.bundleIdentifier,
           !bundleIdentifier.isEmpty {
            launchEnvironment["CMUX_BUNDLE_ID"] = bundleIdentifier
        }
        guard let resourceURL else { return launchEnvironment }
        let binURL = resourceURL.appendingPathComponent("bin", isDirectory: true)
        let cliURL = binURL.appendingPathComponent("cmux", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: cliURL.path) else {
            return launchEnvironment
        }
        launchEnvironment["CMUX_BUNDLED_CLI_PATH"] = cliURL.path
        var pathEntries = (launchEnvironment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        pathEntries.removeAll { $0 == binURL.path }
        pathEntries.insert(binURL.path, at: 0)
        launchEnvironment["PATH"] = pathEntries.joined(separator: ":")
        return launchEnvironment
    }

}
