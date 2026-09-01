import Foundation

func cmxIrohIsSafeToken(
    _ value: String,
    maximumUTF8ByteCount: Int = 64
) -> Bool {
    guard (1 ... maximumUTF8ByteCount).contains(value.utf8.count) else {
        return false
    }
    return value.utf8.allSatisfy { byte in
        (48 ... 57).contains(byte)
            || (65 ... 90).contains(byte)
            || (97 ... 122).contains(byte)
            || [45, 46, 58, 95].contains(byte)
    }
}
