import Foundation

/// `terminal-resources {surfaces?}` (capability `terminal-resources-v1`):
/// each terminal's process tree (the shell first, then every descendant)
/// and its terminal host, with cumulative CPU time and memory, read by the
/// daemon when asked. Nothing is sampled in the background, so a CPU
/// percentage needs two calls (the resource hover cards make one per
/// second while a card is open).
public struct TerminalResourcesRequest: DaemonRequest {
    public static let command = "terminal-resources"
    public static let capability = "terminal-resources-v1"

    /// Nil asks for every PTY surface.
    public var surfaces: [SurfaceID]?

    public init(surfaces: [SurfaceID]?) {
        self.surfaces = surfaces
    }

    public struct Process: Decodable, Sendable, Equatable {
        public var pid: Int32
        public var ppid: Int32?
        public var name: String?
        /// Cumulative user plus system CPU time.
        public var cpuNanos: UInt64
        /// Physical footprint on macOS, resident memory on Linux.
        public var memoryBytes: UInt64

        public init(pid: Int32, ppid: Int32? = nil, name: String? = nil, cpuNanos: UInt64, memoryBytes: UInt64) {
            self.pid = pid
            self.ppid = ppid
            self.name = name
            self.cpuNanos = cpuNanos
            self.memoryBytes = memoryBytes
        }

        enum CodingKeys: String, CodingKey {
            case pid, ppid, name
            case cpuNanos = "cpu_ns"
            case memoryBytes = "memory_bytes"
        }
    }

    public struct Terminal: Decodable, Sendable, Equatable {
        public var surface: SurfaceID
        public var pid: Int32?
        /// The `__terminal-host` process that owns the PTY; nil for PTYs
        /// inside the daemon.
        public var host: Process?
        public var processes: [Process]
        public var truncated: Bool

        enum CodingKeys: String, CodingKey {
            case surface, pid, host, processes, truncated
        }

        public init(surface: SurfaceID, pid: Int32?, host: Process?, processes: [Process], truncated: Bool = false) {
            self.surface = surface
            self.pid = pid
            self.host = host
            self.processes = processes
            self.truncated = truncated
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            surface = try container.decode(SurfaceID.self, forKey: .surface)
            pid = try container.decodeIfPresent(Int32.self, forKey: .pid)
            host = try container.decodeIfPresent(Process.self, forKey: .host)
            processes = try container.decodeIfPresent([Process].self, forKey: .processes) ?? []
            truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        }
    }

    public struct Response: Decodable, Sendable, Equatable {
        /// Monotonic nanoseconds on the daemon host's clock.
        public var sampledAtNanos: UInt64
        public var terminals: [Terminal]
        public var missing: [SurfaceID]

        enum CodingKeys: String, CodingKey {
            case sampledAtNanos = "sampled_at_ns"
            case terminals, missing
        }

        public init(sampledAtNanos: UInt64, terminals: [Terminal], missing: [SurfaceID] = []) {
            self.sampledAtNanos = sampledAtNanos
            self.terminals = terminals
            self.missing = missing
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sampledAtNanos = try container.decode(UInt64.self, forKey: .sampledAtNanos)
            terminals = try container.decodeIfPresent([Terminal].self, forKey: .terminals) ?? []
            missing = try container.decodeIfPresent([SurfaceID].self, forKey: .missing) ?? []
        }
    }
}
