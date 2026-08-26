public import Foundation
public import CMUXMobileCore
import Observation

/// How the phone reaches a paired Mac. Tailscale is the only connection
/// method: an authorized Tailscale route established by entering the pairing
/// code shown on the Mac once, which authorizes that exact peer.
///
/// Older builds persisted other method choices ("automatic", "iroh",
/// "direct"); ``MobileConnectionMethodStore`` and the paired-Mac store map
/// every persisted value to `.tailscale` on read so stored pairings survive.
public enum MobileConnectionMethod: String, CaseIterable, Sendable {
    case tailscale
}

extension MobileConnectionMethod {
    /// Mapping into the diagnostics payload enum, so a future second method
    /// becomes a compile error here instead of silently misreporting.
    var diagnosticMethod: DiagnosticConnectionMethod {
        switch self {
        case .tailscale: .tailscale
        }
    }
}

/// Persists the user's connection-method choice.
///
/// Tailscale is the only method; the store keeps reading (and normalizing)
/// values persisted by older builds. It never manufactures Tailscale
/// authorization by itself; a pairing code entry remains the authorization
/// event for each Mac.
///
/// The backing `UserDefaults` is injected so the store is testable without
/// touching `.standard`; the app constructs it at the composition root.
@MainActor
@Observable
public final class MobileConnectionMethodStore {
    /// The defaults key under which the connection method is stored.
    public static let methodKey = "dev.cmux.mobile.connectionMethod.v1"

    // UserDefaults is Apple-documented thread-safe; OK to hold nonisolated.
    private nonisolated(unsafe) let defaults: UserDefaults
    private let diagnosticLog: DiagnosticLog?
    @ObservationIgnored private var continuations:
        [UUID: AsyncStream<MobileConnectionMethod>.Continuation] = [:]

    /// The user's current connection-method choice.
    public var method: MobileConnectionMethod {
        didSet {
            guard method != oldValue else { return }
            defaults.set(method.rawValue, forKey: Self.methodKey)
            diagnosticLog?.recordAppEvent(
                .connectionMethodPreferenceChanged,
                count: method.diagnosticMethod.rawValue
            )
            for continuation in continuations.values {
                continuation.yield(method)
            }
        }
    }

    /// Create a store backed by the given defaults.
    ///
    /// Every persisted raw value (including the retired "automatic", "iroh",
    /// and "direct" choices from older builds) reads as `.tailscale`, so a
    /// stored preference never crashes or drops an existing pairing.
    public init(defaults: UserDefaults, diagnosticLog: DiagnosticLog? = nil) {
        self.defaults = defaults
        self.diagnosticLog = diagnosticLog
        self.method = defaults.string(forKey: Self.methodKey)
            .flatMap(MobileConnectionMethod.init(rawValue:)) ?? .tailscale
        recordConfiguredMethodDiagnostic()
    }

    /// Records the currently configured method into the diagnostics ring.
    ///
    /// Called at composition and on every foreground so any shared report
    /// window states the configuration even after the bounded ring has rolled
    /// past app launch; `connectionMethodPreferenceChanged` alone only marks
    /// transitions.
    public func recordConfiguredMethodDiagnostic() {
        diagnosticLog?.recordAppEvent(
            .connectionMethodConfigured,
            count: method.diagnosticMethod.rawValue
        )
    }

    /// Observes connection-method changes, beginning with the current method.
    ///
    /// Each subscriber owns an independent stream. Cancelling iteration removes
    /// that subscriber without affecting Settings or other connection owners.
    public func changes() -> AsyncStream<MobileConnectionMethod> {
        let id = UUID()
        let current = method
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.continuations[id] = nil
                }
            }
        }
    }
}
