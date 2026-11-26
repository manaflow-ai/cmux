/// The resource or cost category represented by one Resources row.
public enum CloudTreeMachineResourceMetric: String, Equatable, Sendable {
    case cpu
    case memory
    case disk
    case usage
}
