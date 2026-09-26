/// One CPU, memory, disk, or usage row inside a Resources section.
public struct CloudTreeMachineResourceRow: Equatable, Sendable {
    public init(
        metric: CloudTreeMachineResourceMetric,
        title: String,
        detail: String,
        accessibilityLabel: String
    ) {
        self.metric = metric
        self.title = title
        self.detail = detail
        self.accessibilityLabel = accessibilityLabel
    }

    public let metric: CloudTreeMachineResourceMetric
    public let title: String
    public let detail: String
    public let accessibilityLabel: String
}
