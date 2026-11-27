/// One opened node: its line, the two lines under it (what `zoom` shows)
/// or, for a message's own line, the message whole.
public struct ChiefMemoryNode: Sendable, Equatable, Decodable {
    /// A message of the log.
    public struct Message: Sendable, Equatable, Decodable {
        /// Its id in the log.
        public var id: UInt64
        /// Its kind: user, talk, tool, echo, note or work.
        public var kind: String
        /// Its whole text.
        public var text: String

        public init(id: UInt64, kind: String, text: String) {
            self.id = id
            self.kind = kind
            self.text = text
        }
    }

    /// The node's own line.
    public var line: ChiefMemoryLine
    /// The two lines under it; empty for a message's own line.
    public var children: [ChiefMemoryLine]
    /// The message a level-0 line summarizes.
    public var message: Message?

    public init(line: ChiefMemoryLine, children: [ChiefMemoryLine] = [], message: Message? = nil) {
        self.line = line
        self.children = children
        self.message = message
    }

    enum CodingKeys: String, CodingKey { case children, message }

    public init(from decoder: any Decoder) throws {
        line = try ChiefMemoryLine(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        children = try c.decodeIfPresent([ChiefMemoryLine].self, forKey: .children) ?? []
        message = try c.decodeIfPresent(Message.self, forKey: .message)
    }
}
