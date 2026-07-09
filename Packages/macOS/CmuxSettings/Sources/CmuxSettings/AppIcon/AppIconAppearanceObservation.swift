import Foundation

/// A cancellable handle to an in-flight appearance/launch observation.
///
/// This is the one sanctioned KVO seam for the app-icon subsystem. The live
/// app-icon work observes `NSApplication.effectiveAppearance`, which Foundation
/// exposes only through key-value observing (`NSKeyValueObservation`), and it
/// also registers a one-shot `NotificationCenter` launch observer. Both tokens
/// are AppKit/Foundation types the AppKit-free settings package must not name,
/// so the package depends on this `AnyObject` protocol and the app target
/// supplies the concrete tokens. `NSKeyValueObservation` conforms to it in the
/// app target; the launch-observer cleanup is wrapped in a small token there.
///
/// The contract is intentionally a callback token rather than an `AsyncStream`:
/// the appearance change must be applied synchronously inside the observer's
/// `lastAppliedImageName` dedup turn (no suspension window between "appearance
/// changed" and "icon reapplied"), and the five behavior tests assert exact
/// call counts against that synchronous turn. Surfacing the change as an
/// `AsyncStream` would insert a hop that changes those observable counts, so the
/// stream conversion is deferred to a dedicated modernization pass, not folded
/// into this byte-faithful lift.
public protocol AppIconAppearanceObservation: AnyObject {
    /// Cancels the observation and releases the underlying token.
    func invalidate()
}
