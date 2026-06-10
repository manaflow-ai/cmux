public import CMUXMobileCore
public import CmuxMobileTransport
import Foundation

/// The connection doctor's live environment probes, as injectable closures.
///
/// ``MobileShellComposite/makeConnectionDoctor()`` builds the real set over
/// the shell's injected seams (reachability, the paired-Mac store, the device
/// registry, the system interface walk, a raw TCP dial); tests inject
/// deterministic closures. Every probe is individually bounded (the dial's
/// connect deadline, the registry's request timeout), so a full doctor run
/// finishes in a few seconds even when the Mac is asleep.
public struct ConnectionDoctorProbes: Sendable {
    /// Captures the shell-state snapshot the probes run against (candidate
    /// routes, paired Mac, account, last classified pairing failure).
    public var connection: @Sendable () async -> ConnectionDoctorProbeResults.ConnectionSnapshot
    /// Observes whether the system has a satisfied network path.
    public var isOnline: @Sendable () async -> Bool?
    /// Observes the phone-side tailnet status.
    public var tailscale: @Sendable () async -> TailscaleStatus?
    /// Dials one host/port route and classifies how the dial resolved.
    public var dial: @Sendable (CmxAttachRoute) async -> ConnectionDoctorProbeResults.DialOutcome
    /// Cross-checks the saved routes against the device registry.
    public var registry: @Sendable (_ macDeviceID: String?, _ stored: [CmxAttachRoute]) async
        -> ConnectionDoctorProbeResults.RegistryCrossCheck

    /// Creates a probe set.
    /// - Parameters:
    ///   - connection: Shell-state snapshot source.
    ///   - isOnline: Network-path observation.
    ///   - tailscale: Phone-side tailnet observation.
    ///   - dial: Bounded TCP dial of one route.
    ///   - registry: Registry cross-check of the saved routes.
    public init(
        connection: @escaping @Sendable () async -> ConnectionDoctorProbeResults.ConnectionSnapshot,
        isOnline: @escaping @Sendable () async -> Bool?,
        tailscale: @escaping @Sendable () async -> TailscaleStatus?,
        dial: @escaping @Sendable (CmxAttachRoute) async -> ConnectionDoctorProbeResults.DialOutcome,
        registry: @escaping @Sendable (_ macDeviceID: String?, _ stored: [CmxAttachRoute]) async
            -> ConnectionDoctorProbeResults.RegistryCrossCheck
    ) {
        self.connection = connection
        self.isOnline = isOnline
        self.tailscale = tailscale
        self.dial = dial
        self.registry = registry
    }
}

extension ConnectionDoctorProbes {
    /// How long a doctor dial waits for a TCP connect before classifying the
    /// route as timed out. Deliberately shorter than the transport's 15s
    /// default: the doctor only proves routability, and a checklist that
    /// resolves in a few seconds is the point.
    public static let dialTimeoutNanoseconds: UInt64 = 4 * 1_000_000_000

    /// Dials `route` once over a raw TCP transport and classifies the result.
    ///
    /// A successful connect is closed immediately: the doctor proves that
    /// something accepted the port, it never speaks the RPC protocol.
    /// - Parameter route: The host/port route to dial.
    /// - Returns: The classified ``ConnectionDoctorProbeResults/DialOutcome``.
    public static func dialOverTCP(_ route: CmxAttachRoute) async -> ConnectionDoctorProbeResults.DialOutcome {
        let transport: CmxNetworkByteTransport
        do {
            transport = try CmxNetworkByteTransport(
                route: route,
                connectTimeoutNanoseconds: dialTimeoutNanoseconds
            )
        } catch {
            return .failed
        }
        do {
            try await transport.connect()
            await transport.close()
            return .accepted
        } catch {
            await transport.close()
            return classify(dialError: error)
        }
    }

    /// Maps a transport connect error onto a dial outcome.
    /// - Parameter dialError: The error ``CmxNetworkByteTransport/connect()`` threw.
    /// - Returns: The classified outcome (generic failures map to ``ConnectionDoctorProbeResults/DialOutcome/failed``).
    public static func classify(dialError: any Error) -> ConnectionDoctorProbeResults.DialOutcome {
        guard let transportError = dialError as? CmxNetworkByteTransportError else {
            return .failed
        }
        switch transportError {
        case .connectionTimedOut:
            return .timedOut
        case let .connectionFailed(_, kind):
            switch kind {
            case .connectionRefused: return .refused
            case .hostUnreachable: return .unreachable
            case .timedOut: return .timedOut
            case .dnsFailed: return .dnsFailed
            case .permissionDenied: return .permissionDenied
            case .secureChannelFailed, .generic: return .failed
            }
        default:
            return .failed
        }
    }
}
