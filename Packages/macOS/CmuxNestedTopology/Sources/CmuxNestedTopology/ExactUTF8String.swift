/// Byte-exact identity for opaque protocol strings.
///
/// Swift `String` equality uses Unicode canonical equivalence, while provider
/// identifiers and protocol tokens are opaque UTF-8 values. This wrapper keeps
/// those representations distinct without changing their public string APIs.
struct ExactUTF8String: Comparable, Hashable, Sendable {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    static func == (lhs: ExactUTF8String, rhs: ExactUTF8String) -> Bool {
        lhs.value.utf8.elementsEqual(rhs.value.utf8)
    }

    static func < (lhs: ExactUTF8String, rhs: ExactUTF8String) -> Bool {
        lhs.value.utf8.lexicographicallyPrecedes(rhs.value.utf8)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(value.utf8.count)
        for byte in value.utf8 {
            hasher.combine(byte)
        }
    }
}
