/// One thing Update Everything replaces on a machine: the app, the machine's cmux daemon or an
/// agent CLI, from the version it runs to the version it gets.
///
/// ```swift
/// UpdateEverythingChange(name: "Claude Code", from: "2.1.3", to: "2.2.0")
/// ```
public nonisolated struct UpdateEverythingChange: Sendable, Codable, Equatable {
    /// The id the machine's update path takes (an agent CLI's harness id); nil for the app and
    /// the daemon.
    public var id: String?
    /// What changes, as the person knows it ("cmux NEXT", "cmux", "Claude Code").
    public var name: String
    /// The version running now; nil when the machine does not say.
    public var from: String?
    /// The version it gets; nil when only "newer" is known (a Sparkle update not yet described).
    public var to: String?

    /// - Parameters:
    ///   - id: The harness id, for an agent CLI.
    ///   - name: What changes.
    ///   - from: The running version, when known.
    ///   - to: The new version, when known.
    public init(id: String? = nil, name: String, from: String? = nil, to: String? = nil) {
        self.id = id
        self.name = name
        self.from = from
        self.to = to
    }
}
