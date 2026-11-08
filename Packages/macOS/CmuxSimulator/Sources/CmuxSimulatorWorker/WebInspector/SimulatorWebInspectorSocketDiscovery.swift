import Darwin
import Foundation

struct SimulatorWebInspectorSocketDiscovery: Sendable {
    let subprocessRunner: SimulatorSubprocessRunner
    let userIdentifier: uid_t

    init(
        subprocessRunner: SimulatorSubprocessRunner,
        userIdentifier: uid_t = getuid()
    ) {
        self.subprocessRunner = subprocessRunner
        self.userIdentifier = userIdentifier
    }

    func socketPath(deviceIdentifier: String) async throws -> String {
        let service = "user/\(userIdentifier)/com.apple.webinspectord"
        let result = try await subprocessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: [
                "simctl", "spawn", deviceIdentifier,
                "launchctl", "print", service,
            ]
        )
        guard result.status == 0,
              let path = parseSocketPath(result.standardOutput) else {
            throw SimulatorWebInspectorError.unavailable(
                result.standardError.isEmpty
                    ? "The selected Simulator did not publish a Web Inspector socket."
                    : result.standardError
            )
        }
        return path
    }

    func parseSocketPath(_ launchctlOutput: String) -> String? {
        for line in launchctlOutput.split(whereSeparator: \.isNewline) {
            guard line.contains("RWI_LISTEN_SOCKET"),
                  let separator = line.range(of: "=>") else { continue }
            let path = line[separator.upperBound...].trimmingCharacters(in: .whitespaces)
            guard isAllowedSocketPath(path) else { return nil }
            return path
        }
        return nil
    }

    private func isAllowedSocketPath(_ path: String) -> Bool {
        guard path.hasSuffix("/com.apple.webinspectord_sim.socket") else { return false }
        return path.hasPrefix("/private/var/tmp/com.apple.launchd.")
            || path.hasPrefix("/private/tmp/com.apple.launchd.")
    }
}
