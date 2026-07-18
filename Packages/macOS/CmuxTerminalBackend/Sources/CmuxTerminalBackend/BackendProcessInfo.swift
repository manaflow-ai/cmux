/// Process metadata owned by the persistent PTY backend.
public struct BackendProcessInfo: Decodable, Equatable, Sendable {
    public let processID: UInt32?
    public let command: [String]?
    public let workingDirectory: String?
    public let controllingTTYName: String?

    enum CodingKeys: String, CodingKey {
        case processID = "pid"
        case command
        case workingDirectory = "cwd"
        case controllingTTYName = "tty"
    }
}
