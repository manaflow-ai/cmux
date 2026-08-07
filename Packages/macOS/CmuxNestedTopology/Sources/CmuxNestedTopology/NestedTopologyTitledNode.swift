/// Provider node whose published title may include a trusted local overlay.
protocol NestedTopologyTitledNode: Equatable {
    /// Effective title currently published by cmux.
    var title: NestedNodeTitle? { get }

    /// Returns the node with a trusted local title applied.
    func replacingTitle(with title: NestedNodeTitle) -> Self
}
