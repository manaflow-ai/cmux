/// The snapshot formats a viewer can restore (`terminal-snapshot-v1`).
public struct TerminalSnapshotSupport: Hashable, Sendable, Codable {
    public var format: String
    public var versions: [Int]

    public init(versions: [Int]) {
        self.format = "ghostsnp"
        self.versions = versions
    }
}
