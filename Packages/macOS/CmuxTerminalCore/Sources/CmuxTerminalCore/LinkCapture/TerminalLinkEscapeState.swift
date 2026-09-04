enum TerminalLinkEscapeState: Sendable {
    case none
    case escape
    case csi
    case osc
    case oscEscape
}
