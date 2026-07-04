import Foundation

/// Progress reported while downloading and compiling the Parakeet CoreML model.
public struct ParakeetDownloadProgress: Equatable, Sendable {
    /// Fraction complete in `0...1`.
    public let fractionCompleted: Double
    /// Short phase string suitable for compact settings UI.
    public let phaseDescription: String

    /// Creates a download progress snapshot.
    /// - Parameters:
    ///   - fractionCompleted: Fraction complete in `0...1`.
    ///   - phaseDescription: Short phase string for the current operation.
    public init(fractionCompleted: Double, phaseDescription: String) {
        self.fractionCompleted = min(max(fractionCompleted, 0), 1)
        self.phaseDescription = phaseDescription
    }
}
