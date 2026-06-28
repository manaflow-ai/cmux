public import CmuxSettings

/// Pure close-confirmation gating shared by the window's Bonsplit
/// tab/pane-close witnesses (`splitTabBar(_:shouldCloseTab:inPane:)` and
/// `splitTabBar(_:shouldClosePane:)`).
///
/// Each witness used to inline the same two steps: classify the close's origin
/// into a ``CloseTabCloseSource`` (the tab's inline X button vs. the close
/// shortcut) and ask a ``CloseTabWarningReading`` store whether that source,
/// combined with the tab's per-panel `requiresConfirmation` state, should raise
/// the confirmation dialog. This value type owns both steps so the witnesses
/// forward one decision instead of repeating the mapping and the store call.
///
/// The store is constructor-injected (`CloseTabWarningStore(defaults: .standard)`
/// in the app, a fixed fake in tests) and read on each call, so the gating
/// reflects the live warning toggles at decision time, exactly as the legacy
/// inline `CloseTabWarningStore(defaults: .standard).shouldConfirmClose(...)`
/// reads did.
public struct TabCloseConfirmationPolicy: Sendable {
    private let store: any CloseTabWarningReading

    /// Creates a policy reading the supplied close-tab warning settings.
    public init(store: any CloseTabWarningReading) {
        self.store = store
    }

    /// Classifies a close request by its origin: the tab's inline close (X)
    /// button when `isTabCloseButton`, otherwise the close shortcut (or an
    /// equivalent menu/palette action). This is the legacy
    /// `tabCloseButtonClose ? .tabCloseButton : .shortcut` mapping the witnesses
    /// repeated.
    public func source(isTabCloseButton: Bool) -> CloseTabCloseSource {
        isTabCloseButton ? .tabCloseButton : .shortcut
    }

    /// Whether closing should present the confirmation dialog, combining the
    /// caller's per-tab `requiresConfirmation` state with the warning toggles
    /// for the classified ``CloseTabCloseSource``.
    public func requiresConfirmation(
        requiresConfirmation: Bool,
        isTabCloseButton: Bool
    ) -> Bool {
        store.shouldConfirmClose(
            requiresConfirmation: requiresConfirmation,
            source: source(isTabCloseButton: isTabCloseButton)
        )
    }
}
