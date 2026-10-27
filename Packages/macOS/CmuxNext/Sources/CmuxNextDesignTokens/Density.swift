/// The two density families code branches on (``DensityTokens/family``): Compact, the default,
/// and Comfortable. `Metrics` reads every metric through the active ``DensityTokens``.
public nonisolated enum Density: String, Sendable, CaseIterable, Codable {
    case compact
    case comfortable
}
