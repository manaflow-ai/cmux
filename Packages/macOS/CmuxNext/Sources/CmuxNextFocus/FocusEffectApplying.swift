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
}
