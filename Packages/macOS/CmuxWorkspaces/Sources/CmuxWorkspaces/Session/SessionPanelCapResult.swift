public import Foundation

/// What ``SessionPanelCap/cap(_:)`` kept and how many panel ids it left out.
public struct SessionPanelCapResult: Equatable, Sendable {
    /// The panel ids the snapshot keeps, in their original order.
    public let retainedPanelIds: [UUID]
    /// How many panel ids came after the cap. Zero when every id fit.
    public let omittedCount: Int

    /// Creates a result.
    ///
    /// - Parameters:
    ///   - retainedPanelIds: The panel ids the snapshot keeps, in order.
    ///   - omittedCount: How many panel ids were left out.
    public init(retainedPanelIds: [UUID], omittedCount: Int) {
        self.retainedPanelIds = retainedPanelIds
        self.omittedCount = omittedCount
    }
}
