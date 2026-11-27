import Foundation

/// Outcome of resolving a pending activation against the current results.
public struct CommandPalettePendingActivationResolutionResult: Equatable {
    /// The activation to run, or nil when nothing should activate yet.
    public let resolvedActivation: CommandPaletteResolvedActivation?
    /// Whether the pending activation should be cleared.
    public let shouldClearPendingActivation: Bool

    /// Creates a resolution result.
    public init(
        resolvedActivation: CommandPaletteResolvedActivation?,
        shouldClearPendingActivation: Bool
    ) {
        self.resolvedActivation = resolvedActivation
        self.shouldClearPendingActivation = shouldClearPendingActivation
    }
}
