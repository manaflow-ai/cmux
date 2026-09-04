/// Selects how cmux communicates with its managed Chromium child.
enum ChromiumDebuggingTransport: Equatable, Sendable {
    /// Private, inherited file descriptors with no TCP listener.
    case pipe

    /// A loopback TCP listener that external CDP clients may attach to.
    case loopback(port: Int)
}
