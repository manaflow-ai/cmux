import Foundation

/// `machine-listening-tcp` (cmux-tui protocol 12, `machine-listening-tcp-v1`):
/// the host's `ss -H -ltn` table, read over the machine's own link.
public struct MachineListeningTCPRequest: DaemonRequest {
    public struct Response: Decodable, Sendable {
        public var stdout: String
        /// The dev servers the table names, by the daemon's rule (cmux-tui-core `machine_ports.rs`):
        /// no system or ephemeral port, each once. Nil from a daemon before the rule.
        public var ports: [Listener]?
    }

    /// One port the machine offers to open, and the program the table names for it.
    public struct Listener: Decodable, Equatable, Sendable {
        public var port: Int
        public var process: String?
        public init(port: Int, process: String? = nil) { self.port = port; self.process = process }
    }
    public static let command = "machine-listening-tcp"

    public init() {}

    /// Distinct listening ports, ascending, from `ss`/`netstat` lines.
    public static func ports(in table: String) -> [Int] {
        var ports = Set<Int>()
        for line in table.split(whereSeparator: \.isNewline) {
            for field in line.split(separator: " ") where field.contains(":") {
                guard let last = field.split(separator: ":").last, let port = Int(last), port > 0 else { continue }
                ports.insert(port)
                break
            }
        }
        return ports.sorted()
    }
}
