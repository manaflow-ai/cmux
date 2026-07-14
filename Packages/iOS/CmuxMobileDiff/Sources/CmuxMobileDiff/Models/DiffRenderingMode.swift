/// Row-layout seam reserved for orientation-driven split rendering in slice 4.
enum DiffRenderingMode: Sendable, Equatable {
    /// One marker column with dual line-number gutters.
    case unified
    /// Side-by-side old and new cells; currently falls back to unified rows.
    case split
}
