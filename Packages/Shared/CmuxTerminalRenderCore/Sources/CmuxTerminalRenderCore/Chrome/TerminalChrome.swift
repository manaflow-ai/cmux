/// What the terminal screen's chrome shows (pure, so the rules are tested
/// without UIKit): the path badge next to the title and the connection
/// banner over the terminal.
public struct TerminalChrome: Sendable, Hashable {
    public struct Badge: Sendable, Hashable {
        public var path: TerminalPath
        /// Whole milliseconds, shown only when the link is slow enough to
        /// matter (above `slowRTTMilliseconds`) or relayed.
        public var rttMilliseconds: Int?
        /// A relayed path or a slow link: the badge draws attention.
        public var isEmphasized: Bool

        public init(path: TerminalPath, rttMilliseconds: Int?, isEmphasized: Bool) {
            self.path = path
            self.rttMilliseconds = rttMilliseconds
            self.isEmphasized = isEmphasized
        }
    }

    public enum Banner: Sendable, Hashable {
        case connecting
        case reconnecting(attempt: Int)
        case offline
    }

    /// transport.md 1.1: RTT is worth showing above 50 ms.
    public static let slowRTTMilliseconds: Double = 50

    public var badge: Badge?
    public var banner: Banner?

    /// - Parameters:
    ///   - hasContent: the screen already shows the terminal (a READY or
    ///     bytes arrived), so a first connect needs no banner after a reconnect.
    ///   - ended: the stream ended (its notice replaces the banner).
    public init(path: TerminalPath?, rttMilliseconds: Double?, connection: TerminalConnectionState?,
                hasContent: Bool, ended: Bool) {
        let isLive = connection == nil || connection == .connected
        if let path, isLive, !ended {
            let relayed = path == .relayed || path == .viaCloudRegion
            let slow = (rttMilliseconds ?? 0) > Self.slowRTTMilliseconds
            let shown = (relayed || slow) ? rttMilliseconds.map { Int($0.rounded()) } : nil
            badge = Badge(path: path, rttMilliseconds: shown, isEmphasized: relayed || slow)
        } else {
            badge = nil
        }
        guard !ended, let connection else {
            banner = nil
            return
        }
        switch connection {
        case .connected: banner = nil
        case .connecting: banner = hasContent ? .reconnecting(attempt: 1) : .connecting
        case .reconnecting(let attempt): banner = .reconnecting(attempt: attempt)
        case .offline: banner = .offline
        }
    }
}
