enum TerminalSurfaceLaunchFormStorage: Equatable, Sendable {
    case command(String)
    case arguments([String])
}
