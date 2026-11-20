/// Attachments of visible terminals started ahead of their surfaces (startup-tti: launch to the first key echoed in a
/// restored terminal).
///
/// The app makes at most one terminal surface per display frame (`ContentPresentationScheduler`), and a surface's
/// IO, whose making starts its attach (connect, identify, attach, replay), was made with the surface. So a
/// relaunched window's terminals began to attach only after the first window frame, one frame apart, and a key
/// typed into one waited for that whole attach after the surface came. A pane that waits for its surface starts its
/// terminal's attach here at once (one socket and no surface each: the surface stays on the frame budget), and the
/// surface takes that attachment when it comes (``take(_:validity:)``), with the replay already in.
///
/// Bounded: one attachment per tab, only for a pane on screen that waits for its surface; one not taken is closed
/// when its tab goes (``drop(_:)``), when it is stale (another validity: the daemon restarted, the surface changed)
/// or after ``limit`` started ahead (``start(_:validity:make:)`` then closes the oldest).
@MainActor
public final class TerminalAttachAhead<IO: AnyObject> {
    nonisolated deinit {}
    /// The most attachments held ahead at once (a window shows a few terminals; a launch at most ``limit``).
    public nonisolated static var limit: Int { 16 }

    private struct Started {
        let validity: String
        let io: IO
    }

    private var started: [String: Started] = [:]
    private var order: [String] = []
    private let close: (IO) -> Void

    /// `close`: ends an attachment no surface took.
    public init(close: @escaping (IO) -> Void) {
        self.close = close
    }

    /// The tabs with an attachment held ahead (tests, diagnostics).
    public var keys: [String] { order }

    /// Starts `key`'s attachment with `make` unless one of this `validity` is held already. Returns whether it made one.
    @discardableResult
    public func start(_ key: String, validity: String, make: () -> IO) -> Bool {
        if let held = started[key] {
            if held.validity == validity { return false }
            drop(key)
        }
        if order.count >= Self.limit, let oldest = order.first { drop(oldest) }
        started[key] = Started(validity: validity, io: make())
        order.append(key)
        return true
    }

    /// The attachment started ahead for `key` at `validity`, handed over once (nil when none; a stale one is closed).
    public func take(_ key: String, validity: String) -> IO? {
        guard let held = started.removeValue(forKey: key) else { return nil }
        order.removeAll { $0 == key }
        guard held.validity == validity else {
            close(held.io)
            return nil
        }
        return held.io
    }

    /// `key`'s tab went: closes its attachment if no surface took it.
    public func drop(_ key: String) {
        guard let held = started.removeValue(forKey: key) else { return }
        order.removeAll { $0 == key }
        close(held.io)
    }
}
