/// Owns the beta preference and capability checks for the terminal files chip.
///
/// The coordinator uses this single seam both to decide whether the chip can
/// mount and to guard the count-only artifact scan that feeds it.
struct TerminalArtifactChipFeatureGate: Equatable, Sendable {
    let isEnabled: Bool

    init(artifactsAvailable: Bool, preferenceEnabled: Bool) {
        self.isEnabled = artifactsAvailable && preferenceEnabled
    }

    /// Runs the chip's count scan only while the feature gate is enabled.
    @MainActor
    func performScan<Result: Sendable>(
        _ scan: @MainActor () async throws -> Result?
    ) async rethrows -> Result? {
        guard isEnabled else { return nil }
        return try await scan()
    }
}
