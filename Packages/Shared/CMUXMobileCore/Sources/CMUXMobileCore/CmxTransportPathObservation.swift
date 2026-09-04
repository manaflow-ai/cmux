import Foundation

/// Optional live-path capability implemented by transports that can report the
/// concrete path carrying application bytes.  The capability is deliberately
/// separate from ``CmxByteTransport`` so older/test transports remain valid and
/// the RPC layer can fail closed to ``CmxTransportPath/unavailable``.
public protocol CmxByteTransportPathObserving: CmxByteTransport {
    /// The path selected for this transport at the instant of the call.
    func currentTransportPath() async -> CmxTransportPath

    /// Emits the initial path and every subsequent path change.  A stream must
    /// finish when the underlying transport is closed.
    func transportPathChanges() async -> AsyncStream<CmxTransportPath>
}

/// Convenience projections shared by path-observing transports.
public extension CmxByteTransportPathObserving {
    /// A stable class for diagnostics even when the concrete path is not known.
    func currentTransportClass() async -> CmxTransportClass? {
        await currentTransportPath().transportClass
    }
}
