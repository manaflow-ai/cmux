/// The path impairment of a run. `shaped` is false for real sockets on
/// loopback (no delay or loss beyond the machine's own).
public struct BenchConditions: Codable, Sendable, Hashable {
    public var shaped: Bool
    public var rttMilliseconds: Double
    public var loss: Double
    public var note: String
}
