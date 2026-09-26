import Foundation

/// Destination for finalized dictation text.
///
/// The package defines the seam; the app target conforms with the focused
/// terminal surface write path so the package never depends on app types.
public protocol DictationTextSink: Sendable {
    /// Inserts dictated text at the active input position.
    ///
    /// - Parameter text: The finalized transcript (already cleaned).
    /// - Returns: `false` when no target accepted the text this time.
    @MainActor func insertDictationText(_ text: String) -> Bool
}
