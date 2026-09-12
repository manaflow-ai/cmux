enum TerminalOSC8State: Equatable, Sendable {
    case none
    case escape
    case command([UInt8])
    case params(command: [UInt8])
    case uri(overflowed: Bool)
    case uriEscape(overflowed: Bool)
    case ignored
    case ignoredEscape
}
