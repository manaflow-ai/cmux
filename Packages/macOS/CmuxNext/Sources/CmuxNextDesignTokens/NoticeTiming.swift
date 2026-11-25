/// How long a connection state the person can do nothing about (reconnecting, retrying, restoring, offline,
/// disconnected) stays out of sight before one line says it: the copy of
/// `schemas/notice-timing/notice-timing.json` `connectionQuietMs`, checked against it by
/// `scripts/cmux-next/check-connection-notices.py`, which also fails a new connection state drawn with no action and
/// no bound. A state the person can act on (one button that fixes it) may show at once.
public nonisolated struct NoticeTiming: Sendable {
    public init() {}

    /// A connection state shows only once it has lasted this long.
    public static let connectionQuiet: Duration = .milliseconds(10_000)
}
