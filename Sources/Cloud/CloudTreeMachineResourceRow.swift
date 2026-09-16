/// One CPU, memory, disk, or usage row inside a Resources section.
struct CloudTreeMachineResourceRow: Equatable {
    enum Metric: String, Equatable {
        case cpu
        case memory
        case disk
        case usage
    }

    let metric: Metric
    let title: String
    let detail: String
    let icon: String
    let accessibilityLabel: String
}
