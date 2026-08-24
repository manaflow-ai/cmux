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

public extension CmxByteTransportPathObserving {
    /// A stable class for diagnostics even when the concrete path is not known.
    func currentTransportClass() async -> CmxTransportClass? {
        await currentTransportPath().transportClass
    }
}

/// The mode captured for one physical dial in the privacy-safe diagnostic ring.
/// Raw values are append-only and intentionally independent of route-kind raw
/// values so adding a route class cannot change historical exports.
public enum DiagnosticTransportMode: Int, Codable, CaseIterable, Hashable, Sendable {
    case automatic = 0
    case lan = 1
    case tailscale = 2
    case iroh = 3
    case direct = 4

    public init(_ mode: CmxTransportMode) {
        switch mode {
        case .automatic: self = .automatic
        case .lan: self = .lan
        case .tailscale: self = .tailscale
        case .iroh: self = .iroh
        case .direct: self = .direct
        }
    }
}

public extension CmxTransportMode {
    /// Stable integer vocabulary used by diagnostic event payloads.
    var diagnosticMode: DiagnosticTransportMode {
        DiagnosticTransportMode(self)
    }
}
