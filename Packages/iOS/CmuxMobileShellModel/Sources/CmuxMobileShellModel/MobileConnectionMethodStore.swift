public import Foundation
public import CMUXMobileCore
import Observation

/// How the phone should reach a paired Mac.
///
/// `relay` is the default: it needs no setup and works from any network. The
/// legacy `automatic` (iroh) and `direct` (iroh pinned to user addresses) raw
/// values no longer decode, so pairings that used them land on the relay
/// default; an explicit `tailscale` choice persists unchanged.
public enum MobileConnectionMethod: String, CaseIterable, Sendable {
    /// Require the user's Tailscale network. Requires entering the Tailscale
    /// pairing code shown on the Mac once, which authorizes that exact peer;
    /// no other method is used as a fallback while this method is selected.
    case tailscale
    /// Dial only the cmux mobile relay (one WebSocket through the HostRelay
    /// Durable Object). Requires the Mac's "Relay Remote Access" toggle; no
    /// other method is ever used as a fallback while this method is selected,
    /// and no other method ever falls back to the relay.
    case relay
}

extension MobileConnectionMethod {
    /// Exhaustive mapping into the diagnostics payload enum, so a future third
    /// method becomes a compile error here instead of silently misreporting.
    var diagnosticMethod: DiagnosticConnectionMethod {
        switch self {
        case .tailscale: .tailscale
        case .relay: .relay
        }
    }
}

/// Persists the user's connection-method choice.
///
/// The choice is exclusive: `relay` dials only the cmux relay, while
/// `tailscale` dials only an authorized Tailscale route. It never manufactures
/// Tailscale authorization by itself; a pairing code entry remains the
/// authorization event for each Mac.
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
    public init(defaults: UserDefaults, diagnosticLog: DiagnosticLog? = nil) {
        self.defaults = defaults
        self.diagnosticLog = diagnosticLog
        if let rawValue = defaults.string(forKey: Self.methodKey),
           let method = MobileConnectionMethod(rawValue: rawValue) {
            self.method = method
        } else {
            // Includes legacy persisted "automatic": the raw value no longer
            // decodes, which IS the migration to the relay default.
            self.method = .relay
        }
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
