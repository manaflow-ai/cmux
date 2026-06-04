import Foundation

/// Maps live surface identities to their sessions and host-event streams,
/// replacing the pre-actor static `registeredSurfaceViews` global.
///
/// Constructed once at the app composition root and injected — never reached
/// through a singleton. `@MainActor` rather than a free-standing actor on
/// purpose: registration happens synchronously during surface creation (main
/// thread) and every libghostty app-level action already hops to the main
/// actor before routing, so main isolation removes the register/dispatch race
/// a separate actor mailbox would introduce, at zero cost on the typing path.
@MainActor
public final class GhosttySurfaceRegistry {
    private struct Entry {
        let session: GhosttySurfaceSession
        let events: AsyncStream<GhosttySurfaceHostEvent>.Continuation
        var title: String?
        var snapshotContextProvider: (@MainActor () -> GhosttySurfaceSnapshotContext?)?
    }

    private var entries: [UInt: Entry] = [:]

    /// Creates an empty registry.
    public init() {}

    /// Registers a surface's session and host-event continuation under its
    /// identity. Called by the engine during surface creation.
    func register(
        identity: UInt,
        session: GhosttySurfaceSession,
        events: AsyncStream<GhosttySurfaceHostEvent>.Continuation
    ) {
        entries[identity] = Entry(session: session, events: events, title: nil, snapshotContextProvider: nil)
    }

    /// Removes a surface. Called by the host when it disposes the surface.
    public func unregister(identity: UInt) {
        entries.removeValue(forKey: identity)
    }

    /// Installs the host's snapshot-context provider for
    /// ``visibleTerminalSnapshot()``. The provider returns `nil` while the
    /// surface is not on screen.
    public func setSnapshotContextProvider(
        identity: UInt,
        provider: @escaping @MainActor () -> GhosttySurfaceSnapshotContext?
    ) {
        entries[identity]?.snapshotContextProvider = provider
    }

    /// The last title libghostty set for `identity`, if any.
    public func title(identity: UInt) -> String? {
        entries[identity]?.title
    }

    /// Routes a focus-input action to the surface's host.
    func dispatchFocusInput(identity: UInt) {
        entries[identity]?.events.yield(.focusInputRequested)
    }

    /// Records and routes a title change to the surface's host.
    func dispatchTitleChanged(identity: UInt, title: String) {
        entries[identity]?.title = title
        entries[identity]?.events.yield(.titleChanged(title))
    }

    /// Routes a bell ring to the surface's host.
    func dispatchBell(identity: UInt) {
        entries[identity]?.events.yield(.bellRang)
    }

    /// "What the user sees": the visible viewport text of every on-screen
    /// surface, for the DEV "Copy Debug Logs" action. Each surface's text is
    /// read on its session's serial executor (never the main thread, which
    /// would contend libghostty's surface lock during a render storm), with a
    /// bounded wait so a wedged render queue degrades to a skipped snapshot
    /// instead of freezing the copy action.
    public func visibleTerminalSnapshot() async -> String {
        var sections: [String] = []
        for entry in entries.values {
            guard let context = entry.snapshotContextProvider?() else { continue }
            let text = await readViewportTextBounded(session: entry.session)
            sections.append(
                "===== visible terminal · grid=\(context.gridDescription) · font=\(context.fontSize) =====\n"
                + (text ?? "(snapshot skipped — render busy)")
            )
        }
        if sections.isEmpty {
            return "===== visible terminal: (no on-screen surface) ====="
        }
        return sections.joined(separator: "\n\n")
    }

    /// Reads a session's viewport text, giving up after 600 ms.
    ///
    /// Bounded deadline (a one-line-justified intended timeout): the wedge it
    /// guards is an uncancellable blocked C call, so the slow read is left to
    /// finish on its own queue while the snapshot proceeds without it. Both
    /// racers hop to the main actor, so the one-shot guard needs no further
    /// synchronization.
    private func readViewportTextBounded(session: GhosttySurfaceSession) async -> String? {
        await withCheckedContinuation { continuation in
            let race = GhosttySnapshotReadRace(continuation)
            Task { @MainActor in
                let text = await session.readText(.viewport)
                race.finish(text)
            }
            Task { @MainActor in
                try? await ContinuousClock().sleep(for: .milliseconds(600))
                race.finish(nil)
            }
        }
    }
}

/// One-shot resume guard for ``GhosttySurfaceRegistry``'s bounded snapshot
/// read: whichever racer (read or deadline) finishes first wins; the loser's
/// `finish` is a no-op.
@MainActor
private final class GhosttySnapshotReadRace {
    private var continuation: CheckedContinuation<String?, Never>?

    init(_ continuation: CheckedContinuation<String?, Never>) {
        self.continuation = continuation
    }

    func finish(_ value: String?) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
