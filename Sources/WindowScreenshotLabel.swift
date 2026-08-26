#if DEBUG
import Foundation

/// Converts an optional screenshot label into one safe filename component.
struct WindowScreenshotLabel: Sendable, Equatable {
    private static let maximumUTF8ByteCount = 80

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
        guard !cleaned.isEmpty else {
            value = "capture"
            return
        }

        var byteCount = 0
        value = String(cleaned.prefix { character in
            let characterByteCount = String(character).utf8.count
            guard byteCount + characterByteCount <= Self.maximumUTF8ByteCount else {
                return false
            }
            byteCount += characterByteCount
            return true
        })
    }
}
#endif
