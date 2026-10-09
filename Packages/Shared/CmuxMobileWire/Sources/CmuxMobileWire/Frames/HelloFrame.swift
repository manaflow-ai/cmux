/// `hello`: the first frame of a session (both planes). The server answers
/// `hello.ok` with the chosen version and the common caps, or `error`
/// `proto.version_unsupported` and closes with 4002.
public struct HelloFrame: Hashable, Sendable, Codable {
    public static let proto = "cmux.mobile/1"

    public var proto: String
    public var min: Int
    public var max: Int
    public var caps: [String]
    public var client: HelloClient
    /// Streams the client holds a mirror of, with the last applied seq.
    public var resume: [StreamPosition]?

    public init(min: Int = 1, max: Int = 1, caps: [String], client: HelloClient, resume: [StreamPosition]? = nil) {
        self.proto = Self.proto
        self.min = min
        self.max = max
        self.caps = caps
        self.client = client
        self.resume = resume
    }
}
