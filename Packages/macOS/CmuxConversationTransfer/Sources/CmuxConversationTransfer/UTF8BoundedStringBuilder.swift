/// Incrementally constructs a valid UTF-8 string without crossing a byte ceiling.
struct UTF8BoundedStringBuilder {
    private let maximumBytes: Int
    private var usedBytes = 0
    private(set) var value = ""

    init(maximumBytes: Int) {
        self.maximumBytes = max(0, maximumBytes)
        value.reserveCapacity(min(self.maximumBytes, 24_000))
    }

    mutating func append(_ text: String) {
        append(text, removesControlCharacters: false)
    }

    /// Removes terminal control bytes while preserving tabs, newlines, and Unicode text.
    mutating func appendPromptSafe(_ text: String) {
        append(text, removesControlCharacters: true)
    }

    private mutating func append(
        _ text: String,
        removesControlCharacters: Bool
    ) {
        guard usedBytes < maximumBytes else { return }
        for scalar in text.unicodeScalars {
            if removesControlCharacters,
               scalar.value != 9,
               scalar.value != 10,
               scalar.value < 32 || (127...159).contains(scalar.value) {
                continue
            }
            let byteCount = scalar.utf8ByteCount
            guard byteCount <= maximumBytes - usedBytes else { return }
            value.unicodeScalars.append(scalar)
            usedBytes += byteCount
        }
    }
}
