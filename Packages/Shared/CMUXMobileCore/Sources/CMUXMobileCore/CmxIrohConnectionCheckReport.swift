/// A privacy-safe, staged explanation of Iroh connection readiness.
public struct CmxIrohConnectionCheckReport: Equatable, Sendable {
    public enum Role: Equatable, Sendable {
        case mobileClient
        case macHost
    }

    public enum StageKind: CaseIterable, Hashable, Sendable {
        case encryptedTransport
        case relayPolicy
        case relayReachability
        case macDiscovery
        case secureSession
    }

    public enum StageStatus: Equatable, Sendable {
        case passed
        case warning
        case failed
        case notApplicable
    }

    public enum RelayReachability: Equatable, Sendable {
        case notConfigured
        case reachable
        case unreachable
        case unavailable
    }

    public enum MacDiscovery: Equatable, Sendable {
        case found
        case missing
        case unavailable
    }

    public enum Recommendation: Equatable, Sendable {
        case none
        case retry
        case checkInternet
        case openMacApp
        case allowRelayTraffic
        case refreshAccount
        case reviewRelaySettings
        case updateOrRepair
    }

    public struct Stage: Identifiable, Equatable, Sendable {
        public var id: StageKind { kind }
        public let kind: StageKind
        public let status: StageStatus

        public init(kind: StageKind, status: StageStatus) {
            self.kind = kind
            self.status = status
        }
    }

    public let role: Role
    public let stages: [Stage]
    public let recommendation: Recommendation
    public let failureKind: DiagnosticFailureKind?
    public let selectedPath: CmxIrohSelectedTransportPath

    public var isReady: Bool {
        !stages.contains { $0.status == .failed }
    }

    public init(
        role: Role,
        snapshot: CmxIrohSettingsSnapshot,
        diagnostics: DiagnosticReport,
        relayReachability: RelayReachability,
        macDiscovery: MacDiscovery = .unavailable
    ) {
        self.role = role
        failureKind = diagnostics.lastFailureKind
        selectedPath = snapshot.selectedTransportPath

        let transportStatus: StageStatus = switch snapshot.runtimeStatus {
        case .inactive, .degraded: .failed
        case .starting: .warning
        case .active, .direct, .relayed, .privateNetwork: .passed
        }
        let policyStatus: StageStatus = switch snapshot.policySource {
        case .server: .passed
        case .cached: .warning
        case .unavailable: .failed
        }
        let relayStatus: StageStatus = switch relayReachability {
        case .notConfigured: .notApplicable
        case .reachable: .passed
        case .unreachable: .failed
        case .unavailable: .failed
        }
        let discoveryStatus: StageStatus
        let sessionStatus: StageStatus
        switch role {
        case .macHost:
            discoveryStatus = .notApplicable
            sessionStatus = .notApplicable
        case .mobileClient:
            discoveryStatus = switch macDiscovery {
            case .found: .passed
            case .missing, .unavailable: .failed
            }
            sessionStatus = snapshot.selectedTransportPath == .unavailable ? .failed : .passed
        }

        stages = [
            Stage(kind: .encryptedTransport, status: transportStatus),
            Stage(kind: .relayPolicy, status: policyStatus),
            Stage(kind: .relayReachability, status: relayStatus),
            Stage(kind: .macDiscovery, status: discoveryStatus),
            Stage(kind: .secureSession, status: sessionStatus),
        ]
        recommendation = Self.recommendation(
            role: role,
            transportStatus: transportStatus,
            policyStatus: policyStatus,
            relayReachability: relayReachability,
            discoveryStatus: discoveryStatus,
            sessionStatus: sessionStatus,
            failureKind: diagnostics.lastFailureKind,
            hasRelayConfigurationProblem: !snapshot.staleRelayIDs.isEmpty
                || snapshot.failureDescription != nil
        )
    }

    private static func recommendation(
        role: Role,
        transportStatus: StageStatus,
        policyStatus: StageStatus,
        relayReachability: RelayReachability,
        discoveryStatus: StageStatus,
        sessionStatus: StageStatus,
        failureKind: DiagnosticFailureKind?,
        hasRelayConfigurationProblem: Bool
    ) -> Recommendation {
        if transportStatus == .failed, failureKind == .offline { return .checkInternet }
        if policyStatus == .failed || hasRelayConfigurationProblem {
            return .reviewRelaySettings
        }
        // Corporate-allowlist advice requires a relay that was actually probed
        // and blocked. An unavailable probe is indeterminate (inactive runtime,
        // unreadable path hints), so it must never send users to IT.
        if relayReachability == .unreachable { return .allowRelayTraffic }
        if transportStatus == .failed { return .refreshAccount }
        if role == .mobileClient, discoveryStatus == .failed { return .openMacApp }
        if role == .mobileClient, sessionStatus == .failed {
            switch failureKind {
            case .identityMismatch, .accountMismatch, .authorizationFailed,
                 .admissionDenied, .secureChannelFailed:
                return .updateOrRepair
            default:
                return .retry
            }
        }
        if relayReachability == .unavailable { return .retry }
        return .none
    }
}
