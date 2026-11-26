/// Applies a window's focus effects to the real world (AppKit, WebKit, CEF, layout, registry context).
///
/// The app's window applier in the app; a recorder in tests.
@MainActor public protocol FocusEffectApplying: AnyObject {
    /// Applies `effects`, which the reducer returned with `state`.
    ///
    /// - Parameters:
    ///   - effects: The effects of one reduced event, in order.
    ///   - state: The state after the event.
    func apply(_ effects: [FocusEffect], state: FocusState)

    /// Runs `send`, whose effects focus what `layout` (the layout change of the same turn) shows, then `layout`; a grant
    /// that makes a Chromium page window key, asked while `send` runs, comes after `layout`.
    ///
    /// A pane close shown in its key's turn granted the page beside the closed pane the keys before its layout gave
    /// that page its next size ahead of the commit, and the page's frames stopped for about 100 ms in about half of the
    /// closes. The default runs `send`, then `layout`, and holds nothing.
    ///
    /// - Parameters:
    ///   - send: Sends the focus event; its effects apply inside it.
    ///   - layout: The layout change the focus goes with.
    func holdingPageGrants(_ send: () -> Void, until layout: () -> Void)
}

extension FocusEffectApplying {
    /// Runs `send`, then `layout`, and holds no grant.
    public func holdingPageGrants(_ send: () -> Void, until layout: () -> Void) {
        send()
        layout()
    }
}
