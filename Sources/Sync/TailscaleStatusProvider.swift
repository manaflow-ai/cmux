import Foundation

struct TailscaleStatus: Equatable, Sendable {
    let running: Bool
    let displayName: String?
    let tailscaleHostname: String?
    let tailscaleIPs: [String]
}

final class TailscaleStatusProvider {
    typealias Runner = (String, [String]) throws -> String

    private let runner: Runner

    init(runner: @escaping Runner = TailscaleStatusProvider.defaultRunner) {
        self.runner = runner
    }

    func currentStatus() async -> TailscaleStatus? {
        let runner = self.runner
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                for binary in Self.binaryCandidates {
                    if let status = try? Self.parse(stdout: runner(binary, ["status", "--json"])) {
                        continuation.resume(returning: status.running ? status : nil)
                        return
                    }
                }
                continuation.resume(returning: nil)
            }
        }
    }

    static func parse(stdout: String) throws -> TailscaleStatus {
        guard let data = stdout.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "cmux.mobile.tailscale", code: 1)
        }
        let backendState = (json["BackendState"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = json["Self"] as? [String: Any]
        let displayName = (payload?["HostName"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hostname = trimTailscaleHostname(payload?["DNSName"] as? String)
        let tailscaleIPs = (payload?["TailscaleIPs"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return TailscaleStatus(
            running: backendState == "Running",
            displayName: displayName?.isEmpty == false ? displayName : nil,
            tailscaleHostname: hostname,
            tailscaleIPs: tailscaleIPs
        )
    }

    static func trimTailscaleHostname(_ value: String?) -> String? {
        guard let value = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\.+$"#, with: "", options: .regularExpression),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static let binaryCandidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "tailscale",
    ]

    private static func defaultRunner(binary: String, arguments: [String]) throws -> String {
        let process = Process()
        if binary.contains("/") {
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [binary] + arguments
        }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderr = String(
                data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            throw NSError(
                domain: "cmux.mobile.tailscale",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: stderr]
            )
        }
        return String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
    }
}
