import Foundation

extension CloudWireGuardHub {
    /// Whether `host` (a literal IP) is one the hub would route: inside the
    /// enrolled `AllowedIPs` when known, else inside the private address ranges.
    /// Public hosts never take the hub.
    public static func routesHost(_ host: String, enrolledRoutes: [String]) -> Bool {
        if !enrolledRoutes.isEmpty {
            return IPNetworkPrefix.host(host, isWithinAnyOf: enrolledRoutes)
        }
        return IPNetworkPrefix.isPrivateAddress(host)
    }

    public enum HubError: Error, LocalizedError, Equatable {
        case exitedDuringStart(status: Int32, output: String)
        case notReady(String)
        case spawnFailed(String)
        case restartsExhausted(String)

        public var errorDescription: String? {
            switch self {
            case .exitedDuringStart(let status, let output):
                let tail = output.split(separator: "\n").suffix(3).joined(separator: " · ")
                return "cmux-tui wg hub exited with status \(status) before its socket was ready" + (tail.isEmpty ? "." : ": \(tail)")
            case .notReady(let detail):
                return "cmux-tui wg hub did not start listening: \(detail)"
            case .spawnFailed(let detail):
                return "cmux-tui wg hub could not be started: \(detail)"
            case .restartsExhausted(let detail):
                return "cmux-tui wg hub keeps exiting; giving up until the next link: \(detail)"
            }
        }
    }

    /// The config file an enrollment wrote; nil when it cannot be read.
    static func configContents(_ enrollment: Enrollment) -> String? {
        try? String(contentsOfFile: enrollment.configPath, encoding: .utf8)
    }
}
