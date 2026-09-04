public import CMUXMobileCore
internal import Foundation

/// Routes privacy-safe network outcomes from ``DiagnosticLog`` to the mobile
/// observability upload pipeline.
///
/// The reporter accepts only fixed diagnostic enums and bounded integers. It
/// deliberately excludes UI-only and high-frequency render events, while
/// retaining connection lifecycle, backend-dependent operations, failures,
/// and user-visible terminal latency signals. Its injected emitter keeps the
/// synchronous ingest path free of network and disk I/O.
public final class MobileNetworkOutcomeReporter: Sendable {
    /// The server-side event name used for every network observation.
    public static let eventName = "ios_network_outcome"

    private let emitter: any AnalyticsEmitting

    /// Creates a reporter backed by a dedicated operational-telemetry emitter.
    ///
    /// - Parameter emitter: A non-blocking emitter whose uploader targets the
    ///   cmux mobile observability endpoint, not the product analytics proxy.
    public init(emitter: any AnalyticsEmitting) {
        self.emitter = emitter
    }

    /// Enqueues one important network or backend-dependent outcome.
    ///
    /// Events outside the fixed policy are ignored. Returns immediately and is
    /// safe to install in ``DiagnosticLog/setEventTap(_:)``.
    ///
    /// - Parameter event: The privacy-safe diagnostic event to consider.
    public func ingest(_ event: DiagnosticEvent) {
        guard let properties = Self.properties(for: event) else { return }
        emitter.capture(Self.eventName, properties)
    }

    /// Flushes outcomes already accepted by ``ingest(_:)``.
    public func flush() async {
        await emitter.flush()
    }

    static func properties(for event: DiagnosticEvent) -> [String: AnalyticsValue]? {
        let appKind = event.code == .appFeatureAction
            ? event.a.flatMap(DiagnosticAppEventKind.init(rawValue:))
            : nil
        let failure = DiagnosticEventPresentation().failureKind(of: event)
        guard Self.isImportant(event: event, appKind: appKind, failure: failure) else {
            return nil
        }

        let presentation = DiagnosticEventPresentation(locale: Locale(identifier: "en_US_POSIX"))
        var properties: [String: AnalyticsValue] = [
            "event_code": .int(Int(event.code.rawValue)),
            "event_name": .string(presentation.name(event.code)),
            "outcome": .string(Self.outcome(for: event, appKind: appKind, failure: failure)),
            "runtime_role": .string(presentation.name(DiagnosticRuntimeRole.mobileClient)),
            "user_usable": .bool(Self.userUsableCodes.contains(event.code)),
        ]

        if let duration = event.ms {
            properties["duration_ms"] = .int(Int(duration))
        }
        if let correlation = event.surface {
            properties["correlation_id"] = .int(Int(correlation))
        }
        if let detail = event.a {
            properties["detail_a"] = .int(detail)
        }
        if let detail = event.b {
            properties["detail_b"] = .int(detail)
        }
        if let detail = event.c {
            properties["detail_c"] = .int(detail)
        }
        if let failure, failure != .none {
            properties["failure"] = .string(presentation.name(failure))
        }
        if let transport = presentation.transportKind(of: event) {
            properties["transport"] = .string(presentation.name(transport))
        }
        if let path = Self.pathKind(for: event) {
            properties["path"] = .string(presentation.name(path))
        }
        if let appKind {
            properties["operation_code"] = .int(appKind.rawValue)
            properties["operation"] = .string(presentation.name(appKind))
        }
        return properties
    }

    private static func isImportant(
        event: DiagnosticEvent,
        appKind: DiagnosticAppEventKind?,
        failure: DiagnosticFailureKind?
    ) -> Bool {
        if importantNetworkCodes.contains(event.code) { return true }
        guard let appKind else { return false }
        if let failure, failure != .none { return true }
        return importantAppKinds.contains(appKind)
    }

    private static func outcome(
        for event: DiagnosticEvent,
        appKind: DiagnosticAppEventKind?,
        failure: DiagnosticFailureKind?
    ) -> String {
        if let failure, failure != .none { return "failure" }
        if event.code == .sessionClosed { return "state" }
        if TransportIncidentPolicy.failureCodes.contains(event.code) { return "failure" }
        if successCodes.contains(event.code) { return "success" }
        if startedCodes.contains(event.code) { return "started" }
        if let appKind {
            if appFailureKinds.contains(appKind) { return "failure" }
            if appSuccessKinds.contains(appKind) { return "success" }
            if appStartedKinds.contains(appKind) { return "started" }
        }
        return "state"
    }

    private static func pathKind(for event: DiagnosticEvent) -> DiagnosticPathKind? {
        switch event.code {
        case .selectedPathChanged:
            event.a.flatMap(DiagnosticPathKind.init(rawValue:))
        case .transportPathEvent:
            event.b.flatMap(DiagnosticPathKind.init(rawValue:))
        default:
            nil
        }
    }

    static let importantNetworkCodes: Set<DiagnosticEventCode> = [
        .connect, .pairOk, .pairFail, .renderGridLag, .livenessResubscribe,
        .streamEnded, .inputSeqBehind, .byteGap, .error, .pairUnreachable,
        .transportDialStarted, .transportDialConnected, .transportDialFailed,
        .hostAuthenticated, .rpcReady, .recoveryStarted, .recoverySucceeded,
        .recoveryFailed, .endpointStarting, .endpointActive, .endpointStopped,
        .endpointFailed, .relayPolicyRefreshStarted, .relayPolicyRefreshSucceeded,
        .relayPolicyRefreshFailed, .selectedPathChanged, .sessionClosed,
        .routeUnavailable, .retryScheduled, .discoveryStarted, .discoverySucceeded,
        .discoveryFailed, .admissionSucceeded, .admissionFailed,
        .hostAuthenticationFailed, .rpcFailed, .transportSessionLifecycle,
        .appLifecycleChanged, .reachabilityChanged, .transportCloseAttribution,
        .transportPathEvent, .transportDialPlanBuilt, .transportPrivateAddressJoin,
        .transportLANDiscovery, .transportDialLegSucceeded, .transportDialLegFailed,
        .lanPublicationState, .transportDialSessionLinked, .transportDialCancelled,
        .transportCloseReason,
    ]

    private static let successCodes: Set<DiagnosticEventCode> = [
        .pairOk, .transportDialConnected, .hostAuthenticated, .rpcReady,
        .recoverySucceeded, .endpointActive, .relayPolicyRefreshSucceeded,
        .discoverySucceeded, .admissionSucceeded, .transportDialLegSucceeded,
    ]

    private static let userUsableCodes: Set<DiagnosticEventCode> = [
        .pairOk, .rpcReady, .recoverySucceeded,
    ]

    private static let startedCodes: Set<DiagnosticEventCode> = [
        .connect, .transportDialStarted, .recoveryStarted, .endpointStarting,
        .relayPolicyRefreshStarted, .discoveryStarted,
    ]

    private static let importantAppKinds: Set<DiagnosticAppEventKind> = [
        .authRestoreStarted, .authRestoreSucceeded, .authRestoreFailed,
        .authSignInStarted, .authCodeRequested, .authCodeRequestFailed,
        .authVerificationStarted, .authSignInSucceeded, .authSignInFailed,
        .authSignInCancelled, .authRevalidationStarted, .authRevalidationSucceeded,
        .authRevalidationFailed, .pushRemoteRegistrationRequested,
        .pushDeviceTokenReceived, .pushDeviceTokenRegistrationFailed,
        .pushBackendSyncStarted, .pushBackendSyncSucceeded, .pushBackendSyncFailed,
        .pairingStarted, .pairingSucceeded, .pairingFailed, .pairingCancelled,
        .computerListRefreshStarted, .computerListRefreshSucceeded,
        .computerListRefreshFailed, .computerRoutesUpdated, .tailscaleStatusChanged,
        .computerSwitchStarted, .computerSwitchSucceeded, .computerSwitchFailed,
        .reconnectStarted, .reconnectSucceeded, .reconnectFailed,
        .presenceStreamStarted, .presenceStreamUpdated, .presenceStreamFailed,
        .deviceRegistryLoadStarted, .deviceRegistryLoadSucceeded,
        .deviceRegistryLoadFailed, .connectionStateChanged,
        .workspaceListRefreshStarted, .workspaceListRefreshSucceeded,
        .workspaceListRefreshFailed, .workspaceStateSyncStarted,
        .workspaceStateSyncSucceeded, .workspaceStateSyncFailed,
        .workspaceStateSyncFellBack, .workspaceOpenStarted, .workspaceOpenSucceeded,
        .workspaceOpenFailed, .terminalStreamSubscribed, .terminalStreamResubscribed,
        .terminalStreamEnded, .terminalReplayStarted, .terminalReplaySucceeded,
        .terminalReplayFailed, .terminalReplayRetried, .terminalInputSubmitted,
        .terminalInputSent, .terminalInputAcknowledged, .terminalInputDropped,
        .terminalOutputReceived, .terminalOutputGapDetected, .terminalRenderLagDetected,
        .terminalViewportReportSucceeded, .terminalViewportReportFailed,
        .terminalScrollFailed, .terminalCreateStarted, .terminalCreateSucceeded,
        .terminalCreateFailed, .irohRelayPreferenceChangeStarted,
        .irohRelayPreferenceChangeSucceeded, .irohRelayPreferenceChangeFailed,
        .irohPathPreferenceChangeStarted, .irohPathPreferenceChangeSucceeded,
        .irohPathPreferenceChangeFailed, .irohCustomRelayUpsertStarted,
        .irohCustomRelayUpsertSucceeded, .irohCustomRelayUpsertFailed,
        .irohCustomRelayRemoveStarted, .irohCustomRelayRemoveSucceeded,
        .irohCustomRelayRemoveFailed, .irohCustomRelayTestStarted,
        .irohCustomRelayTestSucceeded, .irohCustomRelayTestFailed,
        .irohPrivatePathUpsertStarted, .irohPrivatePathUpsertSucceeded,
        .irohPrivatePathUpsertFailed, .irohPrivatePathRemoveStarted,
        .irohPrivatePathRemoveSucceeded, .irohPrivatePathRemoveFailed,
        .connectionMethodConfigured, .connectionMethodPreferenceChanged,
        .foregroundTransportSelected,
    ]

    private static let appStartedKinds: Set<DiagnosticAppEventKind> = [
        .authRestoreStarted, .authSignInStarted, .authCodeRequested,
        .authVerificationStarted, .authRevalidationStarted,
        .pushRemoteRegistrationRequested, .pushBackendSyncStarted, .pairingStarted,
        .computerListRefreshStarted, .computerSwitchStarted, .reconnectStarted,
        .presenceStreamStarted, .deviceRegistryLoadStarted,
        .workspaceListRefreshStarted, .workspaceStateSyncStarted,
        .workspaceOpenStarted, .terminalReplayStarted, .terminalInputSubmitted,
        .terminalCreateStarted, .irohRelayPreferenceChangeStarted,
        .irohPathPreferenceChangeStarted, .irohCustomRelayTestStarted,
        .irohCustomRelayUpsertStarted, .irohCustomRelayRemoveStarted,
        .irohPrivatePathUpsertStarted, .irohPrivatePathRemoveStarted,
    ]

    private static let appSuccessKinds: Set<DiagnosticAppEventKind> = [
        .authRestoreSucceeded, .authSignInSucceeded, .authRevalidationSucceeded,
        .pushDeviceTokenReceived, .pushBackendSyncSucceeded, .pairingSucceeded,
        .computerListRefreshSucceeded, .computerSwitchSucceeded, .reconnectSucceeded,
        .presenceStreamUpdated, .deviceRegistryLoadSucceeded,
        .workspaceListRefreshSucceeded, .workspaceStateSyncSucceeded,
        .workspaceOpenSucceeded, .terminalStreamSubscribed,
        .terminalStreamResubscribed, .terminalReplaySucceeded, .terminalInputSent,
        .terminalInputAcknowledged, .terminalOutputReceived,
        .terminalViewportReportSucceeded, .terminalCreateSucceeded,
        .irohRelayPreferenceChangeSucceeded, .irohPathPreferenceChangeSucceeded,
        .irohCustomRelayUpsertSucceeded, .irohCustomRelayRemoveSucceeded,
        .irohCustomRelayTestSucceeded, .irohPrivatePathUpsertSucceeded,
        .irohPrivatePathRemoveSucceeded,
    ]

    private static let appFailureKinds: Set<DiagnosticAppEventKind> = [
        .authRestoreFailed, .authCodeRequestFailed, .authSignInFailed,
        .authSignInCancelled, .authRevalidationFailed,
        .pushDeviceTokenRegistrationFailed, .pushBackendSyncFailed,
        .pairingFailed, .pairingCancelled, .computerListRefreshFailed,
        .computerSwitchFailed, .reconnectFailed, .presenceStreamFailed,
        .deviceRegistryLoadFailed, .workspaceListRefreshFailed,
        .workspaceStateSyncFailed, .workspaceOpenFailed, .terminalStreamEnded,
        .terminalReplayFailed, .terminalInputDropped, .terminalOutputGapDetected,
        .terminalRenderLagDetected, .terminalViewportReportFailed,
        .terminalScrollFailed, .terminalCreateFailed,
        .irohRelayPreferenceChangeFailed, .irohPathPreferenceChangeFailed,
        .irohCustomRelayUpsertFailed, .irohCustomRelayRemoveFailed,
        .irohCustomRelayTestFailed, .irohPrivatePathUpsertFailed,
        .irohPrivatePathRemoveFailed,
    ]
}
