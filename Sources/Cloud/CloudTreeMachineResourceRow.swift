/// One CPU, memory, disk, or usage row inside a Resources section.
struct CloudTreeMachineResourceRow: Equatable {
    let metric: CloudTreeMachineResourceMetric
    let title: String
    let detail: String
    let accessibilityLabel: String
}
