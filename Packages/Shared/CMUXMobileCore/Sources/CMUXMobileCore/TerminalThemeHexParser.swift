import Foundation

struct TerminalThemeHexParser {
    private let hexDigits = Array("0123456789abcdef".utf8)

    func rawRGBValue(_ value: String?) -> Int? {
        guard var value else { return nil }
        if value.hasPrefix("#") {
            value.removeFirst()
        }
        let bytes = value.utf8
        guard bytes.count == 6, bytes.allSatisfy(isASCIIHexDigit) else { return nil }
        return Int(value, radix: 16)
    }

    func normalizedRGBHex(_ value: String?) -> String? {
        guard let raw = rawRGBValue(value) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 7)
        bytes[0] = UInt8(ascii: "#")
        for index in 0..<6 {
            let shift = (5 - index) * 4
            bytes[index + 1] = hexDigits[(raw >> shift) & 0xF]
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func isASCIIHexDigit(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
            || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
            || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "F"))
    }
}
