import Foundation

/// Follows which screen a VT byte stream leaves active by scanning for the
/// alternate-screen private modes (`CSI ? 47/1047/1049 h|l`) and full reset
/// (`ESC c`). State carries across `feed` calls, so a sequence split between
/// two output chunks is still recognized.
///
/// A cmux-tui `vt-state` replay of an alternate-screen application carries
/// only that screen, so a mirror built from it has an empty primary screen.
/// Feeding the replay tells whether that happened; feeding later output
/// reports when the application returns to the primary screen, which is when
/// the mirror needs a fresh snapshot from the server.
public struct CmuxTUIAlternateScreenTracker: Sendable {
    private enum State: Sendable {
        case ground
        case escape
        case csi
    }

    /// Longest CSI parameter string considered. Longer sequences cannot be
    /// a screen switch and are skipped.
    private static let maxParameterBytes = 64

    /// Whether the stream fed so far ends on the alternate screen.
    public private(set) var isAlternate: Bool
    private var state = State.ground
    private var parameters: [UInt8] = []

    public init(isAlternate: Bool = false) {
        self.isAlternate = isAlternate
    }

    /// Feeds stream bytes. Returns `true` when they switched from the
    /// alternate screen back to the primary screen at least once, even if a
    /// later sequence in the same bytes re-entered the alternate screen.
    @discardableResult
    public mutating func feed(_ bytes: Data) -> Bool {
        var leftAlternate = false
        for byte in bytes {
            switch state {
            case .ground:
                if byte == 0x1B { state = .escape }
            case .escape:
                switch byte {
                case 0x5B: // [
                    state = .csi
                    parameters.removeAll(keepingCapacity: true)
                case 0x63: // c: RIS returns to the primary screen.
                    state = .ground
                    if isAlternate { leftAlternate = true }
                    isAlternate = false
                case 0x1B:
                    break
                default:
                    state = .ground
                }
            case .csi:
                switch byte {
                case 0x1B:
                    state = .escape
                case 0x18, 0x1A: // CAN and SUB abort the sequence.
                    state = .ground
                case 0x20...0x3F:
                    if parameters.count < Self.maxParameterBytes {
                        parameters.append(byte)
                    } else {
                        state = .ground
                    }
                case 0x40...0x7E:
                    state = .ground
                    if apply(final: byte) { leftAlternate = true }
                default:
                    // C0 controls execute inside CSI without ending it.
                    break
                }
            }
        }
        return leftAlternate
    }

    /// Applies one complete CSI; returns whether it left the alternate screen.
    private mutating func apply(final: UInt8) -> Bool {
        guard final == 0x68 || final == 0x6C, parameters.first == 0x3F else { return false } // h, l, ?
        let values = parameters.dropFirst().split(separator: 0x3B).map { String(decoding: $0, as: UTF8.self) }
        guard values.contains(where: { $0 == "47" || $0 == "1047" || $0 == "1049" }) else { return false }
        let enable = final == 0x68
        defer { isAlternate = enable }
        return isAlternate && !enable
    }
}
