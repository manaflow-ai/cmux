public import CmuxNextCompat

/// One open palette page's follow of a source: it calls `changed` each time `listing` gives a new value.
///
/// A source's ``PaletteWorkspaceSource/followChanges(_:)`` returns one; the page keeps it while it shows,
/// and dropping it ends the follow.
///
/// ```swift
/// func followChanges(_ changed: @escaping @MainActor () -> Void) -> AnyObject? {
///     PaletteSourceFollow(listing: { [weak services] in services.map(Self.listing) ?? [] }, changed: changed)
/// }
/// ```
@MainActor
public final class PaletteSourceFollow<Listing: Equatable & Sendable> {
    private let task: Task<Void, Never>

    /// Starts the follow.
    ///
    /// - Parameters:
    ///   - listing: What the page's rows are made of, read under observation tracking. It is read once now, in the
    ///     turn the page read its rows, so a change before the follow's task starts is still a change.
    ///   - changed: Called on the main actor after each change of `listing`.
    public init(listing: @escaping @MainActor @Sendable () -> Listing, changed: @escaping @MainActor () -> Void) {
        let subscribed = listing()
        // task-owner: one open page's follow; ends when the page drops this object (deinit)
        // main-hop-allow: not an action's work: it awaits the source's observation stream; its main-actor work is one compare of the listing and one `changed` (the page's reload), one time per change of the list while the palette shows
        task = Task { @MainActor in
            var last = subscribed
            for await value in ObservationStream(listing) where value != last {
                last = value
                changed()
            }
        }
    }

    // Task.cancel is thread-safe; a palette reset can drop the follow inside an action's task-local scope (cx-t7hu).
    nonisolated deinit { task.cancel() }
}
