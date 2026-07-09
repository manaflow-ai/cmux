import Foundation

/// The reference-identity marker the browser eval lane substitutes for a script
/// that produced JavaScript `undefined`.
///
/// WebKit collapses an `undefined` result to `nil`, which is indistinguishable
/// from a script that returned JSON `null`. ``BrowserControlService`` therefore
/// unwraps the `browser eval` envelope (see ``BrowserEvalEnvelope``) into a value
/// where the `undefined` case becomes this sentinel object rather than `nil`.
/// Downstream normalization (``BrowserControlService/normalizeJSValue(_:)``)
/// matches the sentinel by `is BrowserEvalUndefinedSentinel` and re-materializes
/// the envelope shape on the wire.
///
/// It is a `final class` so the match is by type identity (the legacy app-side
/// `V2BrowserUndefinedSentinel` was likewise a reference marker), and `Sendable`
/// because the worker-lane eval path is nonisolated.
public final class BrowserEvalUndefinedSentinel: Sendable {
    /// Creates a sentinel marker.
    public init() {}
}
