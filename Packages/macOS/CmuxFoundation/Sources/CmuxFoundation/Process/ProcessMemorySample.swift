public import Foundation

/// One process contribution from an already deduplicated descendant snapshot.
public struct ProcessMemorySample: Sendable {
    /// Name used only for fixed family classification; it is never emitted.
    public let name: String
    /// Resident bytes, or `nil` when unavailable; shared pages can be counted repeatedly.
    public let residentBytes: Int64?
    /// Physical footprint, or `nil` when the footprint API was unavailable.
    public let physicalFootprintBytes: Int64?
    /// Inherited workspace identity, consumed only for anonymous ranking.
    public let workspaceID: UUID?

    /// Creates an immutable contribution, distinguishing absent measurements from zero.
    /// - Parameters:
    ///   - name: Kernel process name, consumed only for fixed family classification.
    ///   - residentBytes: Measured RSS, when available.
    ///   - physicalFootprintBytes: Measured physical footprint, when available.
    ///   - workspaceID: Inherited workspace scope, when available.
    public init(
        name: String,
        residentBytes: Int64?,
        physicalFootprintBytes: Int64?,
        workspaceID: UUID?
    ) {
        self.name = name
        self.residentBytes = residentBytes
        self.physicalFootprintBytes = physicalFootprintBytes
        self.workspaceID = workspaceID
    }
}
