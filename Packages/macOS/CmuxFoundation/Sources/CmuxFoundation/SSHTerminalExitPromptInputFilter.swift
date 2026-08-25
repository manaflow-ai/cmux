public import Foundation

/// Recognizes a raw Enter key while ignoring terminal control traffic.
///
/// The filter is intended for a terminal exit prompt after its input queue has
/// been flushed. EOT, focus reports, Kitty CSI-u input, terminal replies, and
/// bracketed-paste contents never count as prompt dismissal.
public struct SSHTerminalExitPromptInputFilter: Sendable {
    private static let escape: UInt8 = 0x1B
    private static let bell: UInt8 = 0x07
    private static let carriageReturn: UInt8 = 0x0D
    private static let lineFeed: UInt8 = 0x0A
    private static let leftBracket: UInt8 = 0x5B
    private static let rightBracket: UInt8 = 0x5D
    private static let backslash: UInt8 = 0x5C
    private static let bracketedPasteStart = Array("200".utf8)
    private static let bracketedPasteEnd = Array("201".utf8)
    private static let maxCSIBytes = 512

    private enum State: Sendable, Equatable {
        case ground
        case escape
        case csi
        case operatingSystemCommand
        case operatingSystemCommandEscape
        case controlString
        case controlStringEscape
        case bracketedPaste
        case bracketedPasteEscape
        case bracketedPasteCSI
    }

    private var state = State.ground
    private var csiBody = [UInt8]()
    private var suppressPairedLineFeed = false

    /// Creates an input filter at a prompt boundary.
    public init() {}

    /// Consumes raw terminal bytes and reports a standalone Enter key.
    ///
    /// - Parameter data: Bytes read after the prompt input queue was flushed.
    /// - Returns: `true` only when a CR or LF arrives outside an escape sequence
    ///   or bracketed paste.
    public mutating func consume(_ data: Data) -> Bool {
        for byte in data {
            if consume(byte) {
                return true
            }
        }
        return false
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        if byte == Self.lineFeed, suppressPairedLineFeed {
            suppressPairedLineFeed = false
            return false
        }
        if byte != Self.lineFeed {
            suppressPairedLineFeed = false
        }

        if byte == Self.carriageReturn || byte == Self.lineFeed {
            switch state {
            case .ground:
                return true
            case .escape, .csi, .operatingSystemCommand, .operatingSystemCommandEscape,
                 .controlString, .controlStringEscape:
                csiBody.removeAll(keepingCapacity: true)
                state = .ground
                suppressPairedLineFeed = byte == Self.carriageReturn
            case .bracketedPaste:
                break
            case .bracketedPasteEscape, .bracketedPasteCSI:
                csiBody.removeAll(keepingCapacity: true)
                state = .bracketedPaste
            }
            return false
        }

        switch state {
        case .ground:
            if byte == Self.escape {
                state = .escape
            }
        case .escape:
            switch byte {
            case Self.leftBracket:
                beginCSI(state: .csi)
            case Self.rightBracket:
                state = .operatingSystemCommand
            case 0x50, 0x58, 0x5E, 0x5F:
                state = .controlString
            case Self.escape:
                break
            default:
                state = .ground
            }
        case .csi:
            consumeCSI(byte, returnsTo: .ground)
        case .operatingSystemCommand:
            if byte == Self.bell {
                state = .ground
            } else if byte == Self.escape {
                state = .operatingSystemCommandEscape
            }
        case .operatingSystemCommandEscape:
            state = byte == Self.backslash ? .ground : .operatingSystemCommand
        case .controlString:
            if byte == Self.escape {
                state = .controlStringEscape
            }
        case .controlStringEscape:
            state = byte == Self.backslash ? .ground : .controlString
        case .bracketedPaste:
            if byte == Self.escape {
                state = .bracketedPasteEscape
            }
        case .bracketedPasteEscape:
            if byte == Self.leftBracket {
                beginCSI(state: .bracketedPasteCSI)
            } else {
                state = .bracketedPaste
            }
        case .bracketedPasteCSI:
            consumeCSI(byte, returnsTo: .bracketedPaste)
        }
        return false
    }

    private mutating func beginCSI(state newState: State) {
        csiBody.removeAll(keepingCapacity: true)
        state = newState
    }

    private mutating func consumeCSI(_ byte: UInt8, returnsTo fallbackState: State) {
        guard byte >= 0x40, byte <= 0x7E else {
            guard byte >= 0x20, byte <= 0x3F, csiBody.count < Self.maxCSIBytes else {
                csiBody.removeAll(keepingCapacity: true)
                state = fallbackState
                return
            }
            csiBody.append(byte)
            return
        }

        if byte == 0x7E, csiBody == Self.bracketedPasteStart, state == .csi {
            state = .bracketedPaste
        } else if byte == 0x7E, csiBody == Self.bracketedPasteEnd, state == .bracketedPasteCSI {
            state = .ground
        } else {
            state = fallbackState
        }
        csiBody.removeAll(keepingCapacity: true)
    }
}
