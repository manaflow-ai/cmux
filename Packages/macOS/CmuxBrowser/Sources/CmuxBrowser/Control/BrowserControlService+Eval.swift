import Foundation

extension BrowserControlService {
    /// The shared `undefined` marker this service substitutes for an eval that
    /// produced JavaScript `undefined`.
    ///
    /// One instance per service value; the worker-lane eval path returns it from
    /// ``unwrapEvalEnvelope(_:)`` and ``normalizeJSValue(_:)`` re-materializes it
    /// into the envelope shape, so callers never construct their own sentinel.
    public var evalUndefinedSentinel: BrowserEvalUndefinedSentinel {
        Self.sharedUndefinedSentinel
    }

    /// A process-wide sentinel shared across every `BrowserControlService` value.
    ///
    /// `BrowserControlService` is a stateless `Sendable` struct, so it cannot hold
    /// per-instance reference state; the sentinel is matched purely by type
    /// identity (`is BrowserEvalUndefinedSentinel`), so one shared instance is
    /// sufficient and keeps the marker free of per-call allocation. The legacy
    /// app held a single sentinel on the controller singleton, so this preserves
    /// the one-instance behavior.
    private static let sharedUndefinedSentinel = BrowserEvalUndefinedSentinel()

    /// Unwraps the raw page-eval result into a value the caller can normalize.
    ///
    /// `browser eval` scripts return a small JSON envelope (see
    /// ``BrowserEvalEnvelope``) so an `undefined` result is distinguishable from a
    /// JSON `null`. This recognizes that envelope by ``BrowserEvalEnvelope/typeKey``
    /// and maps the `undefined` discriminator to ``evalUndefinedSentinel`` and the
    /// value discriminator to the carried payload. A value that is not an envelope
    /// (an internal automation script returning a bare value, or a malformed
    /// dictionary) is passed through unchanged. Byte-identical to the envelope
    /// switch previously inlined at the tail of `v2RunBrowserJavaScript`.
    /// - Parameter value: the raw value returned by the WebKit evaluator.
    /// - Returns: the envelope payload, the undefined sentinel, or `value` itself.
    public func unwrapEvalEnvelope(_ value: Any?) -> Any? {
        guard let dict = value as? [String: Any],
              let type = dict[evalEnvelope.typeKey] as? String else {
            return value
        }
        switch type {
        case evalEnvelope.typeUndefined:
            return evalUndefinedSentinel
        case evalEnvelope.typeValue:
            return dict[evalEnvelope.valueKey]
        default:
            return value
        }
    }

    /// Recursively converts a raw JavaScript evaluation result into a
    /// JSON-serializable value, recognizing this service's own
    /// ``evalUndefinedSentinel`` as the `undefined` envelope shape.
    ///
    /// Convenience over ``normalizeJSValue(_:isUndefinedSentinel:)`` for callers
    /// that produced their `undefined` results through ``unwrapEvalEnvelope(_:)``
    /// (and therefore carry ``evalUndefinedSentinel``), so the app no longer needs
    /// to define or thread its own sentinel type.
    /// - Parameter value: the raw value returned by the WebKit evaluator.
    /// - Returns: a value safe to hand to `JSONSerialization`.
    public func normalizeJSValue(_ value: Any?) -> Any {
        normalizeJSValue(value) { $0 is BrowserEvalUndefinedSentinel }
    }
}
