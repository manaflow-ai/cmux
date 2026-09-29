import Foundation

public struct ShutdownDaemonRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var accepted: Bool?
        public var pid: Int32?
        public var generation: DaemonGeneration?
    }
    public static let command = "shutdown-daemon"
    public var pid: Int32
    public var generation: DaemonGeneration
    public var force: Bool?
    public init(pid: Int32, generation: DaemonGeneration, force: Bool? = nil) {
        self.pid = pid
        self.generation = generation
        self.force = force
    }
}

/// Keeps daemon replay colors in step with the app's Ghostty theme.
public struct SetDefaultColorsRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "set-default-colors"
    public var fg: String?
    public var bg: String?
    public var cursor: String?
    public init(fg: String? = nil, bg: String? = nil, cursor: String? = nil) {
        self.fg = fg
        self.bg = bg
        self.cursor = cursor
    }
}
