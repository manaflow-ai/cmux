import Foundation

struct MobileSearchQueryBounds: Sendable {
    let maxUnicodeScalars = 128
    let maxUTF8Bytes = 512

    func boundedEditingText(_ value: String) -> (value: String, didChange: Bool) {
        var output = String()
        output.reserveCapacity(min(maxUnicodeScalars, maxUTF8Bytes))
        var scalarCount = 0
        var utf8ByteCount = 0
        var didTruncate = false
        for scalar in value.unicodeScalars {
            let scalarUTF8ByteCount = scalar.utf8.count
            guard scalarCount < maxUnicodeScalars,
                  utf8ByteCount + scalarUTF8ByteCount <= maxUTF8Bytes else {
                didTruncate = true
                break
            }
            output.unicodeScalars.append(scalar)
            scalarCount += 1
            utf8ByteCount += scalarUTF8ByteCount
        }

        return (
            value: output,
            didChange: didTruncate
        )
    }

    func normalizedFilterText(_ value: String) -> (value: String, didChange: Bool) {
        let bounded = boundedEditingText(value)
        let output = bounded.value
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            value: trimmed,
            didChange: bounded.didChange || trimmed != output
        )
    }
}
