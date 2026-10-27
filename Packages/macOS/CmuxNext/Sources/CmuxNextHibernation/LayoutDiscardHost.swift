/// Hidden content whose view stays and lets only its laid-out state go: a conversation tab's transcript rows,
/// their cells and bitmaps (``ContentKind/conversation``, p07-memory.md 3.C, task 030). Its owner says what it
/// holds and does the release and the relayout.
@MainActor
package struct DiscardableLayout {
    /// The laid-out state went and was not built again yet.
    package var isReleased: () -> Bool
    /// Nothing in it moves (no animation would lose its frames), so it can go now.
    package var isAtRest: () -> Bool
    /// Lets the laid-out state go; false, and nothing goes, while something moves.
    package var release: () -> Bool
    /// The content shows again: it builds the laid-out state at its next layout in its window, where its size is
    /// the pane's (the lifecycle's show effect runs before the pane puts the view back).
    package var restore: () -> Void

    package init(isReleased: @escaping () -> Bool, isAtRest: @escaping () -> Bool, release: @escaping () -> Bool,
                 restore: @escaping () -> Void) {
        self.isReleased = isReleased
        self.isAtRest = isAtRest
        self.release = release
        self.restore = restore
    }
}

/// When hidden ``DiscardableLayout`` content of one kind lets its layout go, on the App's content lifecycle:
/// after ``ContentDiscardPolicy/standard`` hidden, or Chrome's urgent pace at critical pressure
/// (``ContentDiscardScheduler``). The content's view, its data, its scroll place and any draft stay; only what
/// the show can lay out again goes. Chrome discards a background tab the same way and keeps the tab and its
/// navigation state (chrome/browser/resource_coordinator/tab_lifecycle_unit.cc, `TabLifecycleUnit::Discard`).
///
/// The lifecycle carries the discard as for page tabs (``ContentLifecycleOwner``): a show and a hide are the
/// content's `reveal` and `conceal`, the discard is its `hibernate` event and `release` effect, and its next show
/// the `restore` effect, which asks the content for its layout again and answers `mounted`.
@MainActor
package final class LayoutDiscardHost<Token> {
    /// What the host asks of the content lifecycle that carries its discards (the App's content cache).
    package struct Lifecycle {
        /// `key`'s content is live and hidden (`mountedHidden`).
        package var isHidden: (String) -> Bool
        /// `key`'s content is live and this host's to manage: it leaves the terminal warm set.
        package var adopted: (String) -> Void
        /// Sends `hibernate` for `key` (its `release` effect comes back to the host).
        package var hibernate: (String) -> Void
        /// Sends `mounted` for `key` under the `restore` effect's token.
        package var mounted: (String, Token) -> Void

        package init(isHidden: @escaping (String) -> Bool, adopted: @escaping (String) -> Void, hibernate: @escaping (String) -> Void,
                     mounted: @escaping (String, Token) -> Void) {
            self.isHidden = isHidden
            self.adopted = adopted
            self.hibernate = hibernate
            self.mounted = mounted
        }
    }

    package let scheduler: ContentDiscardScheduler
    private let layout: (String) -> DiscardableLayout?
    private let lifecycle: Lifecycle

    /// - Parameters:
    ///   - scheduler: Says when hidden content goes; this host becomes its host.
    ///   - layout: The content of `key`, nil for a key of another kind or one whose view is gone.
    ///   - lifecycle: The content lifecycle that carries the discards.
    package init(scheduler: ContentDiscardScheduler, layout: @escaping (String) -> DiscardableLayout?, lifecycle: Lifecycle) {
        self.scheduler = scheduler
        self.layout = layout
        self.lifecycle = lifecycle
        scheduler.host = self
    }

    // A generic main-actor class's isolated deinit crashes the Release optimizer (#23050).
    nonisolated deinit {}
}

// The content lifecycle's effects. Each returns false for a key that is not this host's content.
extension LayoutDiscardHost: ContentLifecycleOwner {
    package func contentAdopted(_ key: String) -> Bool {
        guard layout(key) != nil else { return false }
        lifecycle.adopted(key)
        return true
    }

    package func contentDidShow(_ key: String) -> Bool {
        guard layout(key) != nil else { return false }
        scheduler.contentDidShow(key)
        return true
    }

    package func contentDidHide(_ key: String, token: Token) -> Bool {
        guard layout(key) != nil else { return false }
        scheduler.contentDidHide(key)
        return true
    }

    /// The layout goes. Content that started moving since the scheduler looked keeps it: it is then hibernated
    /// with its layout, and its show lays nothing out again.
    package func releaseContent(_ key: String, token: Token) -> Bool {
        guard let content = layout(key) else { return false }
        _ = scheduler.takePrepared(key)
        if content.release() { scheduler.noteDiscarded(key) } else { scheduler.noteDiscardFailed(key) }
        return true
    }

    /// The show asks the content for its layout again (built at the view's next layout in its window), and it is live.
    package func restoreContent(_ key: String, token: Token) -> Bool {
        guard let content = layout(key) else { return false }
        content.restore()
        lifecycle.mounted(key, token)
        return true
    }
}

extension LayoutDiscardHost: ContentDiscardHost {
    /// Ten minutes while it is laid out and hidden; nil once its layout went (or its view did).
    package func discardPolicy(of key: String) -> ContentDiscardPolicy? {
        guard let content = layout(key), !content.isReleased(), lifecycle.isHidden(key) else { return nil }
        return .standard
    }

    /// Nothing keeps it: what the person would lose (a draft, the read state, the messages) is not the layout.
    package func keepReasons(of key: String) -> [CannotDiscardReason] { [] }

    /// Something in it still moves: the scheduler looks again a second later.
    package func isDrawn(_ key: String) -> Bool { layout(key).map { !$0.isAtRest() } ?? false }

    /// Nothing to save: the scroll place stays with the view.
    package func prepareDiscard(_ key: String) async -> ContentViewState? {
        guard discardPolicy(of: key) != nil, !isDrawn(key) else { return nil }
        return ContentViewState()
    }

    package func commitDiscard(_ key: String) { lifecycle.hibernate(key) }
}
