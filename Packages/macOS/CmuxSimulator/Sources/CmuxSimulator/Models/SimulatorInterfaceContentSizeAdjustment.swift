/// A relative Dynamic Type adjustment accepted by `simctl ui content_size`.
public enum SimulatorInterfaceContentSizeAdjustment: String, Codable, CaseIterable, Hashable, Sendable {
    /// Advance to the next larger Dynamic Type category.
    case increment
    /// Move to the next smaller Dynamic Type category.
    case decrement
}
