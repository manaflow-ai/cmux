import Foundation

/// Decodes the C-style quoting Git uses for paths in line-delimited porcelain output.
struct GitCStylePathDecoder: Sendable {
    /// Returns an unquoted path unchanged or decodes a double-quoted Git path.
    /// - Parameter value: The path field after the porcelain `worktree ` prefix.
    /// - Returns: The decoded UTF-8 path, or `nil` for malformed quoting or invalid UTF-8.
    func decodeIfQuoted(_ value: String) -> String? {
        let input = Array(value.utf8)
        guard input.first == Self.quote else { return value }
        guard input.count >= 2, input.last == Self.quote else { return nil }

        var output: [UInt8] = []
        output.reserveCapacity(input.count - 2)
        var index = 1
        let end = input.count - 1
        while index < end {
            let byte = input[index]
            guard byte == Self.backslash else {
                output.append(byte)
                index += 1
                continue
            }

            index += 1
            guard index < end else { return nil }
            let escaped = input[index]
            switch escaped {
            case UInt8(ascii: "a"):
                output.append(0x07)
                index += 1
            case UInt8(ascii: "b"):
                output.append(0x08)
                index += 1
            case UInt8(ascii: "t"):
                output.append(0x09)
                index += 1
            case UInt8(ascii: "n"):
                output.append(0x0A)
                index += 1
            case UInt8(ascii: "v"):
                output.append(0x0B)
                index += 1
            case UInt8(ascii: "f"):
                output.append(0x0C)
                index += 1
            case UInt8(ascii: "r"):
                output.append(0x0D)
                index += 1
            case Self.quote, Self.backslash:
                output.append(escaped)
                index += 1
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var octalValue = 0
                var digitCount = 0
                while index < end,
                      digitCount < 3,
                      input[index] >= UInt8(ascii: "0"),
                      input[index] <= UInt8(ascii: "7") {
                    octalValue = (octalValue * 8) + Int(input[index] - UInt8(ascii: "0"))
                    digitCount += 1
                    index += 1
                }
                guard octalValue <= UInt8.max else { return nil }
                output.append(UInt8(octalValue))
            default:
                return nil
            }
        }
        return String(bytes: output, encoding: .utf8)
    }

    private static let quote = UInt8(ascii: "\"")
    private static let backslash = UInt8(ascii: "\\")
}
