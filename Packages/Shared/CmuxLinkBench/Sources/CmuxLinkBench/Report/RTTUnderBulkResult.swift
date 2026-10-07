/// Echo round trips on the `input` channel while a `bulk` download runs on
/// the same link: the head-of-line cost of bulk on interactive traffic.
public struct RTTUnderBulkResult: Codable, Sendable {
    public var rtt: Distribution
    public var bulkMegabitsPerSecond: Double
    /// Under-bulk minus idle, filled when both ran.
    public var p50DeltaMilliseconds: Double?
    public var p99DeltaMilliseconds: Double?
}
