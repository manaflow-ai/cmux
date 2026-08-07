#if DEBUG
import Foundation

/// Converts an optional screenshot label into one safe filename component.
struct WindowScreenshotLabel: Sendable, Equatable {
    let value: String

    init(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            value = ""
            return
        }

        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_.")
        )
        let scalars = trimmed.unicodeScalars.map {
            allowed.contains($0) ? Character($0) : "-"
        }
        let cleaned = String(scalars)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
        value = cleaned.isEmpty ? "capture" : String(cleaned.prefix(80))
    }
}
#endif
