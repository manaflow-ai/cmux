/// Selects the layout decoding contract for a workspace command entry.
enum CmuxLayoutDecodingMode: Equatable, Sendable {
    /// Enforce the persisted two-child split invariant.
    case strict
    /// Accept one legacy child at the root of a flattened command layout.
    case legacyFlattenedRoot

    var allowsLegacySingleChildSplit: Bool {
        self == .legacyFlattenedRoot
    }
}
