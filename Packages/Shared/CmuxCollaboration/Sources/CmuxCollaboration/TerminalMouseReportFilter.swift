public import Foundation

/// Removes terminal mouse-report escape sequences from shared terminal input.
///
/// Shared terminal mirrors render remote output in a local terminal surface. If
/// that mirror surface enters xterm mouse-reporting mode, ordinary pointer
/// movement can generate escape sequences such as `ESC[<35;12;4M`. Those bytes
/// are terminal protocol reports, not intentional keyboard input, so they must
/// not be forwarded into the authoritative PTY.
public struct TerminalMouseReportFilter: Sendable {
    /// Creates a terminal mouse report filter.
    public init() {}

    /// Returns `data` with complete xterm mouse-report escape sequences removed.
    /// - Parameter data: Input bytes produced by a shared terminal mirror.
    /// - Returns: The input bytes with mouse reports stripped.
    public func filtering(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        let bytes = Array(data)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)

        var index = 0
        while index < bytes.count {
            if let end = mouseReportEnd(in: bytes, startingAt: index) {
                index = end
                continue
            }

            output.append(bytes[index])
            index += 1
        }

        return output.count == bytes.count ? data : Data(output)
    }

    private func mouseReportEnd(in bytes: [UInt8], startingAt index: Int) -> Int? {
        guard index + 2 < bytes.count else { return nil }
        guard bytes[index] == 0x1B, bytes[index + 1] == 0x5B else { return nil }

        if bytes[index + 2] == 0x4D {
            // Legacy X10/UTF-8 format: ESC [ M Cb Cx Cy. UTF-8 coordinates can
            // make this longer, but Ghostty's normal X10 writes are six bytes.
            let end = index + 6
            return end <= bytes.count ? end : nil
        }

        if bytes[index + 2] == 0x3C {
            // SGR / SGR-pixels format: ESC [ < Cb ; Cx ; Cy M|m.
            return csiMouseReportEnd(in: bytes, startingAt: index + 3)
        }

        // URXVT format: ESC [ Cb ; Cx ; Cy M.
        return csiMouseReportEnd(in: bytes, startingAt: index + 2)
    }

    private func csiMouseReportEnd(in bytes: [UInt8], startingAt index: Int) -> Int? {
        var cursor = index
        var parameterCount = 0

        while cursor < bytes.count {
            let byte = bytes[cursor]
            if isDigit(byte) {
                cursor += 1
                continue
            }

            if byte == 0x3B {
                parameterCount += 1
                cursor += 1
                continue
            }

            guard parameterCount == 2, byte == 0x4D || byte == 0x6D else {
                return nil
            }
            return cursor + 1
        }

        return nil
    }

    private func isDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }
}
