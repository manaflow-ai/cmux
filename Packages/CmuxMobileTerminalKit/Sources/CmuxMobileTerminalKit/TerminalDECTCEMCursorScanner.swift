public import Foundation

/// Scans a VT byte chunk for the final DECTCEM cursor show/hide state.
///
/// The render-grid producer forwards `ESC [ ? 2 5 h` (show) and
/// `ESC [ ? 2 5 l` (hide) inside its VT-patch bytes; the surface tracks the
/// last applied state so the cursor overlay matches a TUI that hides the
/// cursor. The last occurrence in the chunk wins. Extracted verbatim from the
/// iOS surface view's `lastCursorVisibility(in:)` so the byte scan is testable.
public struct TerminalDECTCEMCursorScanner {
    private init() {}

    /// Returns the final cursor-visibility state in `data`, or `nil` when the
    /// chunk contains no DECTCEM show/hide sequence.
    ///
    /// - Parameter data: The VT byte chunk about to be applied to the surface.
    /// - Returns: `true` for show, `false` for hide, `nil` when unchanged.
    public static func lastVisibility(in data: Data) -> Bool? {
        // ESC [ ? 2 5 (h|l)
        let prefix: [UInt8] = [0x1B, 0x5B, 0x3F, 0x32, 0x35]
        guard data.count >= 6 else { return nil }
        var result: Bool?
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var i = 0
            let end = bytes.count - 5
            while i < end {
                if bytes[i] == prefix[0],
                   bytes[i + 1] == prefix[1],
                   bytes[i + 2] == prefix[2],
                   bytes[i + 3] == prefix[3],
                   bytes[i + 4] == prefix[4] {
                    let final = bytes[i + 5]
                    if final == 0x68 { result = true; i += 6; continue }   // 'h'
                    if final == 0x6C { result = false; i += 6; continue }  // 'l'
                }
                i += 1
            }
        }
        return result
    }
}
