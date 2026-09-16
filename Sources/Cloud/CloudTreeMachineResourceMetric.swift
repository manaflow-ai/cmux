/// The resource or cost category represented by one Resources row.
enum CloudTreeMachineResourceMetric: String, Equatable {
    case cpu
    case memory
    case disk
    case usage

    /// The SF Symbol used in the shared leading icon column for this metric.
    var icon: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip.fill"
        case .disk: return "internaldrive.fill"
        case .usage: return "chart.bar.fill"
        }
    }
}
