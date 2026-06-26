private extension String {
    /// Pack this string's UTF-8 bytes into a big-endian four-char code,
    /// matching the AppleScript scripting-definition split-direction constants.
    var fourCharCode: UInt32 {
        utf8.reduce(0) { ($0 << 8) + UInt32($1) }
    }
}

extension SplitDirection {
    /// Map an AppleScript split-direction four-char code
    /// (`GSrt`/`GSlf`/`GSdn`/`GSup`) to a split direction, returning `nil` for
    /// any other code. Byte-faithful home of the AppleScript `split` command's
    /// direction decode used by `CmuxScriptTerminal`'s split handler.
    public init?(fourCharCode code: UInt32) {
        switch code {
        case "GSrt".fourCharCode: self = .right
        case "GSlf".fourCharCode: self = .left
        case "GSdn".fourCharCode: self = .down
        case "GSup".fourCharCode: self = .up
        default: return nil
        }
    }
}
