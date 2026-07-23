import Foundation

extension GhosttyNSView {
    /// Returns true for terminal control input rather than printable text.
    nonisolated func isControlCharacterScalar(_ scalar: UnicodeScalar) -> Bool {
        scalar.value < 0x20
    }

    /// Filters AppKit fallback payloads to text that libghostty should receive.
    nonisolated func shouldSendText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        if text.count == 1, let scalar = text.unicodeScalars.first {
            return !isControlCharacterScalar(scalar)
        }
        return true
    }
}
