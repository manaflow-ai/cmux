public import Foundation
public import CMUXMobileCore
import Observation

/// How the phone should reach a paired Mac.
public enum MobileConnectionMethod: String, CaseIterable, Sendable {
    /// Dial the built-in encrypted peer-to-peer transport (direct paths with
    /// managed relays as fallback). The default; no setup required.
    case automatic
    /// Require the user's Tailscale network. Requires entering the Tailscale
    /// pairing code shown on the Mac once, which authorizes that exact peer;
    /// Iroh is never used as a fallback while this method is selected.
    case tailscale
    /// Dial only the user-enabled direct addresses configured on the
    /// Computer (LAN, WireGuard, or any other reachable network). No other
    /// method is ever used as a fallback while this method is selected.
    case direct
}

extension MobileConnectionMethod {
    /// Exhaustive mapping into the diagnostics payload enum, so a future third
    /// method becomes a compile error here instead of silently misreporting.
    var diagnosticMethod: DiagnosticConnectionMethod {
        switch self {
        case .automatic: .automatic
        case .tailscale: .tailscale
        case .direct: .direct
        }
    }
}

/// Persists the user's connection-method choice.
///
/// The choice is exclusive: `automatic` uses the built-in encrypted transport,
/// while `tailscale` dials only an authorized Tailscale route. It never
/// manufactures Tailscale authorization by itself; a pairing code entry remains
/// the authorization event for each Mac.
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
            self.method = .automatic
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
