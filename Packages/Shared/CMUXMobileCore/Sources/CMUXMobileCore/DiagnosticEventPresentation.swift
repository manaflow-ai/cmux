import Foundation

/// Decodes a ``DiagnosticEvent`` into privacy-safe text for reports and
/// telemetry sinks.
///
/// The event recorder deliberately stores only bounded integers. Formatting
/// happens here, after recording, so hot transport paths stay allocation-free
/// while every exported title and payload explains itself without a decoder.
/// Stable machine names remain available through the `name(_:)` overloads for
/// Sentry fingerprints, tags, and search attributes.
public struct DiagnosticEventPresentation: Sendable {
    private let localization: DiagnosticLocalization

    /// Creates a presenter that resolves report copy for `locale`.
    ///
    /// - Parameter locale: Locale used for human-readable titles and values.
    public init(locale: Locale = .current) {
        self.localization = DiagnosticLocalization(locale: locale)
    }

    /// One decoded key/value pair of a described event.
    public struct Field: Sendable, Equatable {
        /// Stable semantic key suitable for structured telemetry.
        public let key: String
        /// Human-readable value suitable for display.
        public let value: String

        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    /// A human-readable event title plus decoded payload fields.
    public struct DescribedEvent: Sendable, Equatable {
        /// Human-readable event title, for example `Transport dial failed`.
        public let name: String
        /// Decoded payload fields in a stable order.
        public let fields: [Field]

        public init(name: String, fields: [Field]) {
            self.name = name
            self.fields = fields
        }
    }

    /// The stable machine name of an event code.
    public func name(_ code: DiagnosticEventCode) -> String {
        String(describing: code)
    }

    /// The stable machine name of a failure kind.
    public func name(_ kind: DiagnosticFailureKind) -> String {
        String(describing: kind)
    }

    /// The stable machine name of a transport kind.
    public func name(_ kind: DiagnosticTransportKind) -> String {
        String(describing: kind)
    }

    /// The stable machine name of a path kind.
    public func name(_ kind: DiagnosticPathKind) -> String {
        String(describing: kind)
    }

    /// The stable machine name of a session lifecycle kind.
    public func name(_ kind: DiagnosticSessionLifecycleKind) -> String {
        String(describing: kind)
    }

    /// The stable machine name of an app lifecycle phase.
    public func name(_ phase: DiagnosticAppLifecyclePhase) -> String {
        String(describing: phase)
    }

    /// The stable machine name of an app-wide iOS feature event.
    public func name(_ kind: DiagnosticAppEventKind) -> String {
        String(describing: kind)
    }

    /// The stable machine name of a terminal toolbar action.
    public func name(_ action: DiagnosticTerminalToolbarAction) -> String {
        String(describing: action)
    }

    /// The stable machine name of a terminal zoom action.
    public func name(_ action: DiagnosticTerminalZoomAction) -> String {
        String(describing: action)
    }

    /// The stable machine name of a primary navigation destination.
    public func name(_ tab: DiagnosticPrimaryTab) -> String {
        String(describing: tab)
    }

    /// The stable machine name of a primary search owner.
    public func name(_ scope: DiagnosticSearchScope) -> String {
        String(describing: scope)
    }

    /// The stable machine name of a terminal toolbar configuration mutation.
    public func name(_ action: DiagnosticToolbarConfigurationAction) -> String {
        String(describing: action)
    }

    /// The stable machine name of a feedback delivery route.
    public func name(_ route: DiagnosticFeedbackRoute) -> String {
        String(describing: route)
    }

    /// The stable machine name of a toast style.
    public func name(_ style: DiagnosticToastStyle) -> String {
        String(describing: style)
    }

    /// The stable machine name of a toast dismissal reason.
    public func name(_ reason: DiagnosticToastDismissReason) -> String {
        String(describing: reason)
    }

    /// The stable machine name of a runtime role.
    public func name(_ role: DiagnosticRuntimeRole) -> String {
        String(describing: role)
    }

    /// The stable machine name of a Simulator stream lifecycle edge.
    public func name(_ kind: DiagnosticSimulatorStreamLifecycle) -> String {
        String(describing: kind)
    }

    /// The stable machine name of a Simulator frame lifecycle edge.
    public func name(_ kind: DiagnosticSimulatorFrameLifecycle) -> String {
        String(describing: kind)
    }

    /// The stable machine name of a Simulator input lifecycle edge.
    public func name(_ kind: DiagnosticSimulatorInputLifecycle) -> String {
        String(describing: kind)
    }

    /// The stable machine name of a Simulator input kind.
    public func name(_ kind: DiagnosticSimulatorInputKind) -> String {
        String(describing: kind)
    }

    /// The stable machine name of a Simulator hardware button kind.
    public func name(_ kind: DiagnosticSimulatorHardwareButtonKind) -> String {
        String(describing: kind)
    }

    /// The stable machine name of a Simulator pointer phase.
    public func name(_ phase: DiagnosticSimulatorPointerPhase) -> String {
        String(describing: phase)
    }

    /// The stable machine name of a Simulator ownership state.
    public func name(_ state: DiagnosticSimulatorOwnershipState) -> String {
        String(describing: state)
    }

    /// The stable machine name of a Simulator coordinate mapping state.
    public func name(_ state: DiagnosticSimulatorCoordinateState) -> String {
        String(describing: state)
    }

    /// Human-readable name of a diagnostic failure category.
    public func displayName(_ kind: DiagnosticFailureKind) -> String {
        switch kind {
        case .none: localized("diagnostics.failure.none", defaultValue: "No failure")
        case .offline: localized("diagnostics.failure.offline", defaultValue: "Offline")
        case .timedOut: localized("diagnostics.failure.timedOut", defaultValue: "Timed out")
        case .connectionRefused: localized("diagnostics.failure.connectionRefused", defaultValue: "Connection refused")
        case .hostUnreachable: localized("diagnostics.failure.hostUnreachable", defaultValue: "Host unreachable")
        case .permissionDenied: localized("diagnostics.failure.permissionDenied", defaultValue: "Permission denied")
        case .dnsFailed: localized("diagnostics.failure.dnsFailed", defaultValue: "DNS lookup failed")
        case .secureChannelFailed: localized("diagnostics.failure.secureChannelFailed", defaultValue: "Secure channel failed")
        case .unsupportedRoute: localized("diagnostics.failure.unsupportedRoute", defaultValue: "Unsupported route")
        case .noRoute: localized("diagnostics.failure.noRoute", defaultValue: "No route available")
        case .credentialUnavailable: localized("diagnostics.failure.credentialUnavailable", defaultValue: "Credentials unavailable")
        case .policyUnavailable: localized("diagnostics.failure.policyUnavailable", defaultValue: "Relay policy unavailable")
        case .endpointUnavailable: localized("diagnostics.failure.endpointUnavailable", defaultValue: "Endpoint unavailable")
        case .identityMismatch: localized("diagnostics.failure.identityMismatch", defaultValue: "Host identity mismatch")
        case .admissionDenied: localized("diagnostics.failure.admissionDenied", defaultValue: "Client admission denied")
        case .authorizationFailed: localized("diagnostics.failure.authorizationFailed", defaultValue: "Authorization failed")
        case .accountMismatch: localized("diagnostics.failure.accountMismatch", defaultValue: "Account mismatch")
        case .protocolViolation: localized("diagnostics.failure.protocolViolation", defaultValue: "Protocol violation")
        case .connectionClosed: localized("diagnostics.failure.connectionClosed", defaultValue: "Connection closed")
        case .superseded: localized("diagnostics.failure.superseded", defaultValue: "Superseded by a newer attempt")
        case .cancelled: localized("diagnostics.failure.cancelled", defaultValue: "Cancelled")
        case .transportIdleTimedOut: localized("diagnostics.failure.transportIdleTimedOut", defaultValue: "Transport idle timed out")
        case .admissionLeaseExpired: localized("diagnostics.failure.admissionLeaseExpired", defaultValue: "Admission lease expired")
        case .admissionRevalidationFailed: localized("diagnostics.failure.admissionRevalidationFailed", defaultValue: "Admission revalidation failed")
        case .sendQueueOverflow: localized("diagnostics.failure.sendQueueOverflow", defaultValue: "Send queue overflow")
        case .routeGated: localized("diagnostics.failure.routeGated", defaultValue: "Route already connecting")
        case .payloadTooLarge: localized("diagnostics.failure.payloadTooLarge", defaultValue: "Payload too large")
        case .resourceLimitReached: localized("diagnostics.failure.resourceLimitReached", defaultValue: "Resource limit reached")
        case .attachmentCountLimitReached: localized("diagnostics.failure.attachmentCountLimitReached", defaultValue: "Attachment count limit reached")
        case .attachmentAggregateSizeLimitReached: localized("diagnostics.failure.attachmentAggregateSizeLimitReached", defaultValue: "Attachment size limit reached")
        case .localStateUnavailable: localized("diagnostics.failure.localStateUnavailable", defaultValue: "Local state unavailable")
        case .unknown: localized("diagnostics.failure.unknown", defaultValue: "Unknown failure")
        }
    }

    /// Human-readable name of a transport category.
    public func displayName(_ kind: DiagnosticTransportKind) -> String {
        switch kind {
        case .unknown: localized("diagnostics.transport.unknown", defaultValue: "Unknown transport")
        case .tailscale: localized("diagnostics.transport.tailscale", defaultValue: "Tailscale")
        case .websocket: localized("diagnostics.transport.websocket", defaultValue: "WebSocket")
        case .debugLoopback: localized("diagnostics.transport.debugLoopback", defaultValue: "Debug loopback")
        }
    }

    /// Human-readable name of a configured connection method.
    public func displayName(_ method: DiagnosticConnectionMethod) -> String {
        switch method {
        case .automatic: localized("diagnostics.connectionMethod.automatic", defaultValue: "Auto-Connect")
        case .tailscale: localized("diagnostics.connectionMethod.tailscale", defaultValue: "Tailscale Only")
        case .direct: localized("diagnostics.connectionMethod.direct", defaultValue: "Direct")
        }
    }

    /// Human-readable name of a selected network path.
    public func displayName(_ kind: DiagnosticPathKind) -> String {
        switch kind {
        case .unknown: localized("diagnostics.path.unknown", defaultValue: "Unknown path")
        case .direct: localized("diagnostics.path.direct", defaultValue: "Direct")
        case .relay: localized("diagnostics.path.relay", defaultValue: "Relay")
        case .privateNetwork: localized("diagnostics.path.privateNetwork", defaultValue: "Private network")
        case .loopback: localized("diagnostics.path.loopback", defaultValue: "Loopback")
        }
    }

    /// Human-readable name of a transport-session lifecycle state.
    public func displayName(_ kind: DiagnosticSessionLifecycleKind) -> String {
        switch kind {
        case .established: localized("diagnostics.session.established", defaultValue: "Established")
        case .controlOwnerReleased: localized("diagnostics.session.controlOwnerReleased", defaultValue: "Control owner released")
        case .controlReadFailed: localized("diagnostics.session.controlReadFailed", defaultValue: "Control read failed")
        case .controlWriteFailed: localized("diagnostics.session.controlWriteFailed", defaultValue: "Control write failed")
        case .remoteClosed: localized("diagnostics.session.remoteClosed", defaultValue: "Remote closed")
        case .closedSessionEvicted: localized("diagnostics.session.closedSessionEvicted", defaultValue: "Closed session evicted")
        case .applicationLaneFailed: localized("diagnostics.session.applicationLaneFailed", defaultValue: "Application lane failed")
        case .runtimeDeactivated: localized("diagnostics.session.runtimeDeactivated", defaultValue: "Runtime deactivated")
        case .runtimeReconfigured: localized("diagnostics.session.runtimeReconfigured", defaultValue: "Runtime reconfigured")
        case .explicitlyInvalidated: localized("diagnostics.session.explicitlyInvalidated", defaultValue: "Explicitly invalidated")
        case .allPathsClosed: localized("diagnostics.session.allPathsClosed", defaultValue: "All paths closed")
        }
    }

    /// Human-readable name of an app lifecycle phase.
    public func displayName(_ phase: DiagnosticAppLifecyclePhase) -> String {
        switch phase {
        case .background: localized("diagnostics.phase.background", defaultValue: "Background")
        case .active: localized("diagnostics.phase.active", defaultValue: "Active")
        case .inactive: localized("diagnostics.phase.inactive", defaultValue: "Inactive")
        }
    }

    /// Human-readable name of a report's producing runtime.
    public func displayName(_ role: DiagnosticRuntimeRole) -> String {
        switch role {
        case .unspecified: localized("diagnostics.role.unspecified", defaultValue: "Unspecified runtime")
        case .mobileClient: localized("diagnostics.role.mobileClient", defaultValue: "iOS client")
        case .macHost: localized("diagnostics.role.macHost", defaultValue: "Mac host")
        case .broker: localized("diagnostics.role.broker", defaultValue: "Broker")
        case .relay: localized("diagnostics.role.relay", defaultValue: "Relay")
        }
    }

    /// Decodes an event's payload slots according to its documented schema.
    /// Unknown enum values retain their integer inside an explanatory label so
    /// a newer writer still produces useful text on an older reader.
    public func describe(_ event: DiagnosticEvent) -> DescribedEvent {
        var fields: [Field] = []
        if let surface = event.surface {
            let key: String
            switch event.code {
            case .recoveryStarted, .recoverySucceeded, .recoveryFailed:
                key = "recovery"
            case .transportDialStarted, .transportDialConnected,
                 .transportDialFailed, .transportDialSessionLinked,
                 .transportDialCancelled, .transportSessionLifecycle,
                 .sessionClosed, .transportCloseAttribution,
                 .transportCloseReason, .transportPathEvent,
                 .transportDialPlanBuilt, .transportPrivateAddressJoin,
                 .transportLANDiscovery, .transportDialLegSucceeded,
                 .transportDialLegFailed, .discoveryStarted,
                 .discoverySucceeded, .discoveryFailed:
                key = "peer"
            default:
                key = "surface"
            }
            fields.append(Field(key: key, value: String(surface)))
        }
        if let a = event.a {
            fields.append(decodeA(a, code: event.code))
        }
        if let b = event.b {
            fields.append(decodeB(b, code: event.code))
        }
        if let ms = event.ms {
            fields.append(decodeMilliseconds(ms, code: event.code))
        }
        if let c = event.c {
            fields.append(decodeC(c, event: event))
        }
        return DescribedEvent(name: title(for: event.code), fields: fields)
    }

    /// Renders one event as a standalone human-readable sentence fragment.
    public func summary(_ event: DiagnosticEvent) -> String {
        summary(describe(event))
    }

    /// Renders an already-described event as a title followed by labeled fields.
    public func summary(_ described: DescribedEvent) -> String {
        let visibleFields = described.fields.filter { $0.key != "session" }
        guard !visibleFields.isEmpty else { return described.name }
        let details = visibleFields.map { field in
            localized(
                "diagnostics.summary.field",
                defaultValue: "\(label(for: field.key)): \(field.value)"
            )
        }
        let separator = localized(
            "diagnostics.summary.separator",
            defaultValue: ", "
        )
        return localized(
            "diagnostics.summary.details",
            defaultValue: "\(described.name) (\(details.joined(separator: separator)))"
        )
    }

    /// The failure kind carried in an event's `b` slot, when applicable.
    public func failureKind(of event: DiagnosticEvent) -> DiagnosticFailureKind? {
        guard Self.codesWithFailureB.contains(event.code), let b = event.b else { return nil }
        return DiagnosticFailureKind(rawValue: b)
    }

    /// The transport kind carried in an event's `a` slot, when applicable.
    public func transportKind(of event: DiagnosticEvent) -> DiagnosticTransportKind? {
        guard Self.codesWithTransportA.contains(event.code), let a = event.a else { return nil }
        return DiagnosticTransportKind(rawValue: a)
    }

    /// Event codes whose `b` slot carries a ``DiagnosticFailureKind``.
    private static let codesWithFailureB: Set<DiagnosticEventCode> = [
        .pairFail, .transportDialFailed, .transportDialLegFailed, .recoveryFailed, .endpointFailed,
        .relayPolicyRefreshFailed, .sessionClosed, .routeUnavailable,
        .discoveryFailed, .admissionFailed, .hostAuthenticationFailed,
        .rpcFailed, .transportCloseAttribution, .appFeatureAction,
    ]

    /// Event codes whose `a` slot carries a ``DiagnosticTransportKind``.
    private static let codesWithTransportA: Set<DiagnosticEventCode> = [
        .pairFail,
        .transportDialStarted, .transportDialConnected, .transportDialFailed,
        .hostAuthenticated, .rpcReady,
        .recoveryStarted, .recoverySucceeded, .recoveryFailed,
        .endpointStarting, .endpointActive, .endpointStopped, .endpointFailed,
        .sessionClosed, .routeUnavailable, .retryScheduled,
        .discoveryStarted, .discoverySucceeded, .discoveryFailed,
        .admissionSucceeded, .admissionFailed,
        .hostAuthenticationFailed, .rpcFailed,
    ]

    private func title(for code: DiagnosticEventCode) -> String {
        switch code {
        case .connect:
            localized("diagnostics.event.connect", defaultValue: "Connection attempt started")
        case .pairOk:
            localized("diagnostics.event.pairOk", defaultValue: "Pairing succeeded")
        case .pairFail:
            localized("diagnostics.event.pairFail", defaultValue: "Pairing failed")
        case .renderGridLag:
            localized("diagnostics.event.renderGridLag", defaultValue: "Render grid lagged")
        case .livenessResubscribe:
            localized("diagnostics.event.livenessResubscribe", defaultValue: "Silent event stream resubscribed")
        case .streamEnded:
            localized("diagnostics.event.streamEnded", defaultValue: "Event stream ended")
        case .inputSeqBehind:
            localized("diagnostics.event.inputSeqBehind", defaultValue: "Terminal input acknowledgements fell behind")
        case .byteGap:
            localized("diagnostics.event.byteGap", defaultValue: "Terminal byte gap detected")
        case .error:
            localized("diagnostics.event.error", defaultValue: "Unclassified transport error")
        case .pairUnreachable:
            localized("diagnostics.event.pairUnreachable", defaultValue: "Pairing skipped while offline")
        case .composerPresentedChanged:
            localized("diagnostics.event.composerPresentedChanged", defaultValue: "Composer visibility changed")
        case .composerInputTextChanged:
            localized("diagnostics.event.composerInputTextChanged", defaultValue: "Composer draft changed")
        case .composerViewAppear:
            localized("diagnostics.event.composerViewAppear", defaultValue: "Composer appeared")
        case .composerViewDisappear:
            localized("diagnostics.event.composerViewDisappear", defaultValue: "Composer disappeared")
        case .composerFieldFocusChanged:
            localized("diagnostics.event.composerFieldFocusChanged", defaultValue: "Composer focus changed")
        case .composerActiveTransition:
            localized("diagnostics.event.composerActiveTransition", defaultValue: "Composer activation changed")
        case .composerKeyboardToggleWhilePresented:
            localized(
                "diagnostics.event.composerKeyboardToggleWhilePresented",
                defaultValue: "Keyboard toggled while composer was open"
            )
        case .transportDialStarted:
            localized("diagnostics.event.transportDialStarted", defaultValue: "Transport dial started")
        case .transportDialConnected:
            localized("diagnostics.event.transportDialConnected", defaultValue: "Transport connected")
        case .transportDialFailed:
            localized("diagnostics.event.transportDialFailed", defaultValue: "Transport dial failed")
        case .transportDialSessionLinked:
            localized("diagnostics.event.transportDialSessionLinked", defaultValue: "Transport dial linked to session")
        case .transportDialCancelled:
            localized("diagnostics.event.transportDialCancelled", defaultValue: "Transport dial cancelled")
        case .hostAuthenticated:
            localized("diagnostics.event.hostAuthenticated", defaultValue: "Host authenticated")
        case .rpcReady:
            localized("diagnostics.event.rpcReady", defaultValue: "RPC session ready")
        case .recoveryStarted:
            localized("diagnostics.event.recoveryStarted", defaultValue: "Connection recovery started")
        case .recoverySucceeded:
            localized("diagnostics.event.recoverySucceeded", defaultValue: "Connection recovery succeeded")
        case .recoveryFailed:
            localized("diagnostics.event.recoveryFailed", defaultValue: "Connection recovery failed")
        case .endpointStarting:
            localized("diagnostics.event.endpointStarting", defaultValue: "Peer endpoint starting")
        case .endpointActive:
            localized("diagnostics.event.endpointActive", defaultValue: "Peer endpoint active")
        case .endpointStopped:
            localized("diagnostics.event.endpointStopped", defaultValue: "Peer endpoint stopped")
        case .endpointFailed:
            localized("diagnostics.event.endpointFailed", defaultValue: "Peer endpoint failed")
        case .relayPolicyRefreshStarted:
            localized("diagnostics.event.relayPolicyRefreshStarted", defaultValue: "Relay policy refresh started")
        case .relayPolicyRefreshSucceeded:
            localized("diagnostics.event.relayPolicyRefreshSucceeded", defaultValue: "Relay policy refreshed")
        case .relayPolicyRefreshFailed:
            localized("diagnostics.event.relayPolicyRefreshFailed", defaultValue: "Relay policy refresh failed")
        case .selectedPathChanged:
            localized("diagnostics.event.selectedPathChanged", defaultValue: "Selected network path changed")
        case .sessionClosed:
            localized("diagnostics.event.sessionClosed", defaultValue: "Transport session closed")
        case .routeUnavailable:
            localized("diagnostics.event.routeUnavailable", defaultValue: "No usable transport route")
        case .retryScheduled:
            localized("diagnostics.event.retryScheduled", defaultValue: "Retry scheduled")
        case .discoveryStarted:
            localized("diagnostics.event.discoveryStarted", defaultValue: "Route discovery started")
        case .discoverySucceeded:
            localized("diagnostics.event.discoverySucceeded", defaultValue: "Route discovery succeeded")
        case .discoveryFailed:
            localized("diagnostics.event.discoveryFailed", defaultValue: "Route discovery failed")
        case .admissionSucceeded:
            localized("diagnostics.event.admissionSucceeded", defaultValue: "Client admitted")
        case .admissionFailed:
            localized("diagnostics.event.admissionFailed", defaultValue: "Client admission failed")
        case .hostAuthenticationFailed:
            localized("diagnostics.event.hostAuthenticationFailed", defaultValue: "Host authentication failed")
        case .rpcFailed:
            localized("diagnostics.event.rpcFailed", defaultValue: "RPC session failed")
        case .transportSessionLifecycle:
            localized("diagnostics.event.transportSessionLifecycle", defaultValue: "Transport session state changed")
        case .appLifecycleChanged:
            localized("diagnostics.event.appLifecycleChanged", defaultValue: "App lifecycle changed")
        case .reachabilityChanged:
            localized("diagnostics.event.reachabilityChanged", defaultValue: "Network reachability changed")
        case .transportCloseAttribution:
            localized("diagnostics.event.transportCloseAttribution", defaultValue: "Transport close attributed")
        case .transportCloseReason:
            localized("diagnostics.event.transportCloseReason", defaultValue: "Remote close reason")
        case .transportPathEvent:
            localized("diagnostics.event.transportPathEvent", defaultValue: "Transport path changed")
        case .browserStreamLifecycle:
            localized("diagnostics.event.browserStreamLifecycle", defaultValue: "Browser stream lifecycle")
        case .browserInputReplayed:
            localized("diagnostics.event.browserInputReplayed", defaultValue: "Browser input replayed")
        case .browserEditableFocus:
            localized("diagnostics.event.browserEditableFocus", defaultValue: "Browser editable focus")
        case .browserPanelCreateResolved:
            localized("diagnostics.event.browserPanelCreateResolved", defaultValue: "Browser panel create resolved")
        case .simulatorStreamLifecycle:
            localized("diagnostics.event.simulatorStreamLifecycle", defaultValue: "Simulator stream state changed")
        case .simulatorFrameLifecycle:
            localized("diagnostics.event.simulatorFrameLifecycle", defaultValue: "Simulator frame pipeline changed")
        case .simulatorInputLifecycle:
            localized("diagnostics.event.simulatorInputLifecycle", defaultValue: "Simulator input state changed")
        case .simulatorCoordinateMapped:
            localized("diagnostics.event.simulatorCoordinateMapped", defaultValue: "Simulator touch coordinate mapped")
        case .simulatorOwnershipChanged:
            localized("diagnostics.event.simulatorOwnershipChanged", defaultValue: "Simulator control ownership changed")
        case .appFeatureAction:
            localized("diagnostics.event.appFeatureAction", defaultValue: "App feature event")
        case .transportDialPlanBuilt:
            localized("diagnostics.event.transportDialPlanBuilt", defaultValue: "Direct dial plan assembled")
        case .transportPrivateAddressJoin:
            localized("diagnostics.event.transportPrivateAddressJoin", defaultValue: "Private addresses joined broker port")
        case .transportLANDiscovery:
            localized("diagnostics.event.transportLANDiscovery", defaultValue: "LAN discovery resolved")
        case .transportDialLegSucceeded:
            localized("diagnostics.event.transportDialLegSucceeded", defaultValue: "Direct dial leg connected")
        case .transportDialLegFailed:
            localized("diagnostics.event.transportDialLegFailed", defaultValue: "Direct dial leg failed")
        case .lanPublicationState:
            localized("diagnostics.event.lanPublicationState", defaultValue: "LAN advertisement state changed")
        }
    }

    private func decodeA(_ raw: Int, code: DiagnosticEventCode) -> Field {
        if Self.codesWithTransportA.contains(code) {
            return Field(key: "transport", value: transportName(raw))
        }
        switch code {
        case .selectedPathChanged:
            return Field(key: "path", value: pathName(raw))
        case .transportSessionLifecycle:
            return Field(key: "state", value: sessionLifecycleName(raw))
        case .appLifecycleChanged:
            return Field(key: "phase", value: appLifecycleName(raw))
        case .reachabilityChanged:
            return Field(key: "network", value: reachabilityName(raw))
        case .transportCloseAttribution:
            return Field(key: "initiator", value: closeInitiatorName(raw))
        case .transportPathEvent:
            return Field(key: "operation", value: pathEventName(raw))
        case .inputSeqBehind:
            return Field(key: "local_sequence", value: String(raw))
        case .byteGap:
            return Field(key: "delivered_sequence", value: String(raw))
        case .composerPresentedChanged:
            return Field(key: "composer_visible", value: booleanName(raw))
        case .composerInputTextChanged:
            return Field(key: "draft_size", value: byteCount(raw))
        case .composerFieldFocusChanged:
            return Field(key: "focused", value: booleanName(raw))
        case .composerActiveTransition:
            return Field(key: "composer_active", value: booleanName(raw))
        case .composerKeyboardToggleWhilePresented:
            return Field(key: "terminal_input_focused", value: booleanName(raw))
        case .browserStreamLifecycle:
            return Field(key: "stage", value: browserStreamStageName(raw))
        case .browserInputReplayed:
            return Field(key: "input", value: browserInputKindName(raw))
        case .browserEditableFocus:
            return Field(key: "editable_focused", value: booleanName(raw))
        case .browserPanelCreateResolved:
            return Field(key: "created", value: booleanName(raw))
        case .simulatorStreamLifecycle:
            return Field(key: "state", value: simulatorStreamLifecycleName(raw))
        case .simulatorFrameLifecycle:
            return Field(key: "state", value: simulatorFrameLifecycleName(raw))
        case .simulatorInputLifecycle:
            return Field(key: "state", value: simulatorInputLifecycleName(raw))
        case .simulatorCoordinateMapped:
            return Field(key: "x", value: normalizedCoordinate(raw))
        case .simulatorOwnershipChanged:
            return Field(key: "owner", value: simulatorOwnershipName(raw))
        case .appFeatureAction:
            return Field(key: "operation", value: appEventName(raw))
        case .transportDialPlanBuilt:
            return Field(key: "public_paths", value: String(raw))
        case .transportPrivateAddressJoin:
            return Field(key: "join", value: privateAddressJoinName(raw))
        case .transportLANDiscovery:
            return Field(key: "outcome", value: lanDiscoveryOutcomeName(raw))
        case .transportDialLegSucceeded, .transportDialLegFailed:
            return Field(key: "leg", value: dialLegName(raw))
        case .lanPublicationState:
            return Field(key: "state", value: lanPublicationStateName(raw))
        default:
            return Field(key: "detail_1", value: String(raw))
        }
    }

    private func decodeB(_ raw: Int, code: DiagnosticEventCode) -> Field {
        if Self.codesWithFailureB.contains(code) {
            return Field(key: "failure", value: failureName(raw))
        }
        switch code {
        case .recoveryStarted:
            return Field(key: "trigger", value: recoveryTriggerName(raw))
        case .transportSessionLifecycle:
            return Field(key: "purpose", value: sessionPurposeName(raw))
        case .transportPathEvent:
            return Field(key: "path", value: pathName(raw))
        case .inputSeqBehind:
            return Field(key: "remote_sequence", value: String(raw))
        case .byteGap:
            return Field(key: "next_sequence", value: String(raw))
        case .composerInputTextChanged:
            return Field(key: "draft_empty", value: booleanName(raw))
        case .composerActiveTransition, .composerKeyboardToggleWhilePresented:
            return Field(key: "first_responder", value: responderName(raw))
        case .browserInputReplayed:
            return Field(key: "count", value: String(raw))
        case .browserEditableFocus:
            return Field(key: "outcome", value: browserFocusOutcomeName(raw))
        case .transportDialPlanBuilt:
            return Field(key: "private_fallback_paths", value: String(raw))
        case .discoverySucceeded:
            return Field(key: "bindings", value: String(raw))
        case .transportPrivateAddressJoin:
            return Field(key: "configured_addresses", value: String(raw))
        case .transportLANDiscovery:
            return Field(key: "hints", value: String(raw))
        case .lanPublicationState:
            return Field(key: "reason", value: lanPublicationReasonName(raw))
        case .simulatorStreamLifecycle:
            return Field(key: "owner", value: simulatorOwnershipName(raw))
        case .simulatorFrameLifecycle:
            return Field(key: "frame_sequence", value: String(raw))
        case .simulatorInputLifecycle:
            return Field(key: "input", value: simulatorInputKindName(raw))
        case .simulatorCoordinateMapped:
            return Field(key: "y", value: normalizedCoordinate(raw))
        case .simulatorOwnershipChanged:
            return Field(key: "previous_owner", value: simulatorOwnershipName(raw))
        default:
            return Field(key: "detail_2", value: String(raw))
        }
    }

    private func decodeMilliseconds(
        _ raw: UInt32,
        code: DiagnosticEventCode
    ) -> Field {
        switch code {
        case .renderGridLag:
            return Field(key: "lag", value: duration(raw))
        case .livenessResubscribe:
            return Field(key: "silent_for", value: duration(raw))
        case .retryScheduled:
            return Field(key: "retry_delay", value: duration(raw))
        case .transportCloseAttribution:
            return Field(key: "application_error_code", value: String(raw))
        case .composerActiveTransition, .composerKeyboardToggleWhilePresented:
            return Field(key: "keyboard_height", value: pointCount(Int(raw)))
        default:
            return Field(key: "duration", value: duration(raw))
        }
    }

    private func decodeC(_ raw: Int, event: DiagnosticEvent) -> Field {
        switch event.code {
        case .transportDialPlanBuilt:
            return Field(key: "public_relay_urls", value: String(raw))
        case .discoverySucceeded:
            return Field(key: "relay_fleet", value: String(raw))
        case .transportDialStarted, .transportDialConnected, .transportDialFailed:
            return Field(key: "attempt", value: String(raw))
        case .sessionClosed, .transportSessionLifecycle,
             .transportCloseAttribution, .transportPathEvent:
            return Field(key: "session", value: String(raw))
        case .composerActiveTransition:
            return Field(key: "terminal_input_focused", value: booleanName(raw))
        case .browserStreamLifecycle, .browserInputReplayed,
             .browserEditableFocus, .browserPanelCreateResolved:
            return Field(key: "panel", value: String(raw))
        case .simulatorStreamLifecycle:
            return Field(key: "active_sessions", value: String(raw))
        case .simulatorFrameLifecycle:
            return Field(key: "payload_size", value: byteCount(raw))
        case .simulatorInputLifecycle:
            return Field(
                key: "input_detail",
                value: simulatorInputDetailName(raw, inputKindRaw: event.b)
            )
        case .simulatorCoordinateMapped:
            return Field(key: "mapping", value: simulatorCoordinateStateName(raw))
        case .appFeatureAction:
            if let kind = event.a.flatMap(DiagnosticAppEventKind.init(rawValue:)) {
                switch kind {
                case .terminalToolbarActionUsed:
                    return Field(key: "action", value: terminalToolbarActionName(raw))
                case .terminalZoomChanged:
                    return Field(key: "action", value: terminalZoomActionName(raw))
                case .primaryTabSelected:
                    return Field(key: "tab", value: primaryTabName(raw))
                case .searchPresented, .searchDismissed, .searchResultSelected:
                    return Field(key: "scope", value: searchScopeName(raw))
                case .customToolbarChanged, .terminalShortcutChanged:
                    return Field(key: "change", value: toolbarConfigurationActionName(raw))
                case .feedbackSubmitStarted, .feedbackSubmitSucceeded, .feedbackSubmitFailed:
                    return Field(key: "route", value: feedbackRouteName(raw))
                case .toastPresented, .toastCoalesced, .toastQueued, .toastDropped:
                    return Field(key: "style", value: toastStyleName(raw))
                case .toastDismissed:
                    return Field(key: "reason", value: toastDismissReasonName(raw))
                case .connectionMethodPreferenceChanged, .connectionMethodConfigured:
                    return Field(key: "method", value: connectionMethodName(raw))
                case .foregroundTransportSelected:
                    return Field(key: "transport", value: transportName(raw))
                default:
                    if Self.appEventKindsWithValuePayload.contains(kind) {
                        return Field(key: "value", value: String(raw))
                    }
                }
            }
            return Field(key: "count", value: String(raw))
        default:
            return Field(key: "detail_3", value: String(raw))
        }
    }

    private func appEventName(_ raw: Int) -> String {
        guard let kind = DiagnosticAppEventKind(rawValue: raw) else {
            return localized(
                "diagnostics.unknown.appEvent",
                defaultValue: "Unknown app event (\(raw))"
            )
        }
        return name(kind)
    }

    private func terminalToolbarActionName(_ raw: Int) -> String {
        DiagnosticTerminalToolbarAction(rawValue: raw).map(name)
            ?? unknownPayloadName(raw)
    }

    private func terminalZoomActionName(_ raw: Int) -> String {
        DiagnosticTerminalZoomAction(rawValue: raw).map(name)
            ?? unknownPayloadName(raw)
    }

    private func primaryTabName(_ raw: Int) -> String {
        DiagnosticPrimaryTab(rawValue: raw).map(name)
            ?? unknownPayloadName(raw)
    }

    private func searchScopeName(_ raw: Int) -> String {
        DiagnosticSearchScope(rawValue: raw).map(name)
            ?? unknownPayloadName(raw)
    }

    private func toolbarConfigurationActionName(_ raw: Int) -> String {
        DiagnosticToolbarConfigurationAction(rawValue: raw).map(name)
            ?? unknownPayloadName(raw)
    }

    private func feedbackRouteName(_ raw: Int) -> String {
        DiagnosticFeedbackRoute(rawValue: raw).map(name)
            ?? unknownPayloadName(raw)
    }

    private func toastStyleName(_ raw: Int) -> String {
        DiagnosticToastStyle(rawValue: raw).map(name)
            ?? unknownPayloadName(raw)
    }

    private func toastDismissReasonName(_ raw: Int) -> String {
        DiagnosticToastDismissReason(rawValue: raw).map(name)
            ?? unknownPayloadName(raw)
    }

    private func connectionMethodName(_ raw: Int) -> String {
        DiagnosticConnectionMethod(rawValue: raw).map(displayName)
            ?? unknownPayloadName(raw)
    }

    private func unknownPayloadName(_ raw: Int) -> String {
        localized(
            "diagnostics.unknown.payload",
            defaultValue: "Unknown value (\(raw))"
        )
    }

    private static let appEventKindsWithValuePayload: Set<DiagnosticAppEventKind> = [
        .displayAltScreenNoticeChanged,
        .displayFolderTapChanged,
        .displayHapticsChanged,
        .taskComposerFeatureChanged,
        .terminalFilesFeatureChanged,
        .toastFeatureChanged,
        .displayMissingFilesChanged,
        .displayWorkspaceTitleWrappingChanged,
        .displayWorkspacePreviewLinesChanged,
        .terminalScrollbackRowsChanged,
        .telemetrySharingChanged,
        .notificationPreferenceChanged,
        .terminalDraftStateChanged,
    ]

    private func failureName(_ raw: Int) -> String {
        guard let value = DiagnosticFailureKind(rawValue: raw) else {
            return localized(
                "diagnostics.unknown.failure",
                defaultValue: "Unknown failure (\(raw))"
            )
        }
        return displayName(value)
    }

    private func transportName(_ raw: Int) -> String {
        guard let value = DiagnosticTransportKind(rawValue: raw) else {
            return localized(
                "diagnostics.unknown.transport",
                defaultValue: "Unknown transport (\(raw))"
            )
        }
        return displayName(value)
    }

    private func pathName(_ raw: Int) -> String {
        guard let value = DiagnosticPathKind(rawValue: raw) else {
            return localized(
                "diagnostics.unknown.path",
                defaultValue: "Unknown path (\(raw))"
            )
        }
        return displayName(value)
    }

    private func sessionLifecycleName(_ raw: Int) -> String {
        guard let value = DiagnosticSessionLifecycleKind(rawValue: raw) else {
            return localized(
                "diagnostics.unknown.sessionState",
                defaultValue: "Unknown session state (\(raw))"
            )
        }
        return displayName(value)
    }

    private func appLifecycleName(_ raw: Int) -> String {
        guard let value = DiagnosticAppLifecyclePhase(rawValue: raw) else {
            return localized(
                "diagnostics.unknown.appPhase",
                defaultValue: "Unknown app phase (\(raw))"
            )
        }
        return displayName(value)
    }

    private func dialLegName(_ raw: Int) -> String {
        switch raw {
        case DiagnosticDirectDialLeg.publicPaths.rawValue:
            localized("diagnostics.dialLeg.public", defaultValue: "Public paths")
        case DiagnosticDirectDialLeg.privateFallback.rawValue:
            localized("diagnostics.dialLeg.privateFallback", defaultValue: "Private fallback")
        default:
            localized("diagnostics.unknown.dialLeg", defaultValue: "Unknown leg (\(raw))")
        }
    }

    private func privateAddressJoinName(_ raw: Int) -> String {
        switch raw {
        case DiagnosticPrivateAddressJoinState.notConfigured.rawValue:
            localized("diagnostics.privateJoin.notConfigured", defaultValue: "None configured")
        case DiagnosticPrivateAddressJoinState.joined.rawValue:
            localized("diagnostics.privateJoin.joined", defaultValue: "Joined broker port")
        case DiagnosticPrivateAddressJoinState.brokerPortsStale.rawValue:
            localized(
                "diagnostics.privateJoin.stalePorts",
                defaultValue: "Broker ports missing or stale"
            )
        default:
            localized(
                "diagnostics.unknown.privateJoin",
                defaultValue: "Unknown join state (\(raw))"
            )
        }
    }

    private func lanDiscoveryOutcomeName(_ raw: Int) -> String {
        switch raw {
        case DiagnosticLANDiscoveryOutcome.noAuthority.rawValue:
            localized("diagnostics.lanDiscovery.noAuthority", defaultValue: "No broker LAN authority")
        case DiagnosticLANDiscoveryOutcome.found.rawValue:
            localized("diagnostics.lanDiscovery.found", defaultValue: "Advertisement found")
        case DiagnosticLANDiscoveryOutcome.notFound.rawValue:
            localized("diagnostics.lanDiscovery.notFound", defaultValue: "Advertisement not found")
        case DiagnosticLANDiscoveryOutcome.policyDenied.rawValue:
            localized(
                "diagnostics.lanDiscovery.policyDenied",
                defaultValue: "Local Network permission denied"
            )
        default:
            localized(
                "diagnostics.unknown.lanDiscovery",
                defaultValue: "Unknown discovery outcome (\(raw))"
            )
        }
    }

    private func lanPublicationStateName(_ raw: Int) -> String {
        switch raw {
        case DiagnosticLANPublicationState.inactive.rawValue:
            localized("diagnostics.lanPublication.inactive", defaultValue: "Stopped")
        case DiagnosticLANPublicationState.active.rawValue:
            localized("diagnostics.lanPublication.active", defaultValue: "Advertising")
        case DiagnosticLANPublicationState.unavailable.rawValue:
            localized("diagnostics.lanPublication.unavailable", defaultValue: "Registration failing")
        case DiagnosticLANPublicationState.policyDenied.rawValue:
            localized(
                "diagnostics.lanPublication.policyDenied",
                defaultValue: "Local Network permission denied"
            )
        default:
            localized(
                "diagnostics.unknown.lanPublication",
                defaultValue: "Unknown publication state (\(raw))"
            )
        }
    }

    private func lanPublicationReasonName(_ raw: Int) -> String {
        switch raw {
        case 0:
            localized("diagnostics.lanPublicationReason.applied", defaultValue: "Settings applied")
        case 1:
            localized(
                "diagnostics.lanPublicationReason.listenerDisabled",
                defaultValue: "Listener setting disabled"
            )
        case 2:
            localized(
                "diagnostics.lanPublicationReason.noContext",
                defaultValue: "Runtime context unavailable"
            )
        default:
            localized(
                "diagnostics.unknown.lanPublicationReason",
                defaultValue: "Unknown reason (\(raw))"
            )
        }
    }

    private func sessionPurposeName(_ raw: Int) -> String {
        guard let byte = UInt8(exactly: raw),
              let purpose = CmxTransportSessionPurpose(rawValue: byte)
        else {
            return localized(
                "diagnostics.unknown.sessionPurpose",
                defaultValue: "Unknown session purpose (\(raw))"
            )
        }
        switch purpose {
        case .foregroundControl:
            return localized("diagnostics.purpose.foregroundControl", defaultValue: "Foreground control")
        case .backgroundControl:
            return localized("diagnostics.purpose.backgroundControl", defaultValue: "Background control")
        case .probe:
            return localized("diagnostics.purpose.probe", defaultValue: "Connection probe")
        case .featureLane:
            return localized("diagnostics.purpose.featureLane", defaultValue: "Feature lane")
        }
    }

    private func responderName(_ raw: Int) -> String {
        guard let identity = InputResponderIdentity(rawValue: raw) else {
            return localized(
                "diagnostics.unknown.responder",
                defaultValue: "Unknown responder (\(raw))"
            )
        }
        switch identity {
        case .none:
            return localized("diagnostics.responder.none", defaultValue: "None")
        case .terminalInputProxy:
            return localized("diagnostics.responder.terminalInput", defaultValue: "Terminal input")
        case .ghosttySurface:
            return localized("diagnostics.responder.terminalSurface", defaultValue: "Terminal surface")
        case .uiTextField:
            return localized("diagnostics.responder.textField", defaultValue: "Text field")
        case .uiTextView:
            return localized("diagnostics.responder.textView", defaultValue: "Text view")
        case .other:
            return localized("diagnostics.responder.other", defaultValue: "Other responder")
        }
    }

    private func booleanName(_ raw: Int) -> String {
        switch raw {
        case 0: localized("diagnostics.boolean.no", defaultValue: "No")
        case 1: localized("diagnostics.boolean.yes", defaultValue: "Yes")
        default:
            localized("diagnostics.unknown.state", defaultValue: "Unknown state (\(raw))")
        }
    }

    private func reachabilityName(_ raw: Int) -> String {
        switch raw {
        case 0: localized("diagnostics.reachability.offline", defaultValue: "Offline")
        case 1: localized("diagnostics.reachability.online", defaultValue: "Online")
        default:
            localized(
                "diagnostics.unknown.networkState",
                defaultValue: "Unknown network state (\(raw))"
            )
        }
    }

    private func recoveryTriggerName(_ raw: Int) -> String {
        switch raw {
        case 1: localized("diagnostics.recoveryTrigger.networkChanged", defaultValue: "Network changed")
        case 2: localized("diagnostics.recoveryTrigger.manualRetry", defaultValue: "Manual retry")
        case 3: localized("diagnostics.recoveryTrigger.presenceNotification", defaultValue: "Presence notification")
        case 4: localized("diagnostics.recoveryTrigger.foreground", defaultValue: "App returned to foreground")
        case 5: localized("diagnostics.recoveryTrigger.livenessFailed", defaultValue: "Liveness check failed")
        case 6: localized("diagnostics.recoveryTrigger.streamEnded", defaultValue: "Event stream ended")
        case 7: localized("diagnostics.recoveryTrigger.subscriptionFailed", defaultValue: "Subscription failed to start")
        case 8: localized("diagnostics.recoveryTrigger.writeTimedOut", defaultValue: "Transport write timed out")
        case 9: localized("diagnostics.recoveryTrigger.retryDelayExpired", defaultValue: "Automatic retry delay expired")
        default:
            localized(
                "diagnostics.unknown.recoveryTrigger",
                defaultValue: "Unknown recovery trigger (\(raw))"
            )
        }
    }

    private func closeInitiatorName(_ raw: Int) -> String {
        switch raw {
        case 0: localized("diagnostics.closeInitiator.unknown", defaultValue: "Unknown initiator")
        case 1: localized("diagnostics.closeInitiator.localApp", defaultValue: "Local app")
        case 2: localized("diagnostics.closeInitiator.remotePeer", defaultValue: "Remote peer")
        case 3: localized("diagnostics.closeInitiator.timedOut", defaultValue: "Timed out")
        default:
            localized(
                "diagnostics.unknown.closeInitiator",
                defaultValue: "Unknown close initiator (\(raw))"
            )
        }
    }

    private func browserStreamStageName(_ raw: Int) -> String {
        switch raw {
        case 1: localized("diagnostics.browserStage.started", defaultValue: "Started")
        case 2: localized("diagnostics.browserStage.replaced", defaultValue: "Replaced existing session")
        case 3: localized("diagnostics.browserStage.stopped", defaultValue: "Stopped")
        case 4: localized("diagnostics.browserStage.firstFrame", defaultValue: "First frame delivered")
        default:
            localized(
                "diagnostics.unknown.browserStage",
                defaultValue: "Unknown stage (\(raw))"
            )
        }
    }

    private func browserInputKindName(_ raw: Int) -> String {
        switch raw {
        case 1: localized("diagnostics.browserInput.pointer", defaultValue: "Pointer")
        case 2: localized("diagnostics.browserInput.key", defaultValue: "Key")
        case 3: localized("diagnostics.browserInput.text", defaultValue: "Text")
        case 4: localized("diagnostics.browserInput.keySuppressed", defaultValue: "Key suppressed")
        default:
            localized(
                "diagnostics.unknown.browserInput",
                defaultValue: "Unknown input (\(raw))"
            )
        }
    }

    private func browserFocusOutcomeName(_ raw: Int) -> String {
        switch raw {
        case 0: localized("diagnostics.browserFocus.none", defaultValue: "No editable at point")
        case 1: localized("diagnostics.browserFocus.moved", defaultValue: "Focus moved")
        case 2: localized("diagnostics.browserFocus.already", defaultValue: "Already focused")
        case 3: localized("diagnostics.browserFocus.beacon", defaultValue: "Beacon transition")
        default:
            localized(
                "diagnostics.unknown.browserFocus",
                defaultValue: "Unknown outcome (\(raw))"
            )
        }
    }

    private func pathEventName(_ raw: Int) -> String {
        switch raw {
        case 1: localized("diagnostics.pathOperation.opened", defaultValue: "Opened")
        case 2: localized("diagnostics.pathOperation.closed", defaultValue: "Closed")
        case 3: localized("diagnostics.pathOperation.selected", defaultValue: "Selected")
        case 4: localized("diagnostics.pathOperation.lagged", defaultValue: "Lagged")
        default:
            localized(
                "diagnostics.unknown.pathOperation",
                defaultValue: "Unknown path operation (\(raw))"
            )
        }
    }

    private func simulatorStreamLifecycleName(_ raw: Int) -> String {
        guard let value = DiagnosticSimulatorStreamLifecycle(rawValue: raw) else {
            return localized(
                "diagnostics.unknown.simulatorStreamState",
                defaultValue: "Unknown stream state (\(raw))"
            )
        }
        switch value {
        case .startRequested:
            return localized("diagnostics.simulator.stream.startRequested", defaultValue: "Start requested")
        case .started:
            return localized("diagnostics.simulator.stream.started", defaultValue: "Started")
        case .locked:
            return localized("diagnostics.simulator.stream.locked", defaultValue: "Locked by another controller")
        case .startFailed:
            return localized("diagnostics.simulator.stream.startFailed", defaultValue: "Start failed")
        case .stopRequested:
            return localized("diagnostics.simulator.stream.stopRequested", defaultValue: "Stop requested")
        case .stopped:
            return localized("diagnostics.simulator.stream.stopped", defaultValue: "Stopped")
        case .closed:
            return localized("diagnostics.simulator.stream.closed", defaultValue: "Closed")
        case .restartRequested:
            return localized("diagnostics.simulator.stream.restartRequested", defaultValue: "Restart requested")
        case .pausedForBackground:
            return localized("diagnostics.simulator.stream.pausedForBackground", defaultValue: "Paused for background")
        case .descriptorApplied:
            return localized("diagnostics.simulator.stream.descriptorApplied", defaultValue: "Descriptor applied")
        case .stalled:
            return localized("diagnostics.simulator.stream.stalled", defaultValue: "Stalled (no frames or keepalives)")
        case .stopFailed:
            return localized("diagnostics.simulator.stream.stopFailed", defaultValue: "Stop failed")
        }
    }

    private func simulatorFrameLifecycleName(_ raw: Int) -> String {
        guard let value = DiagnosticSimulatorFrameLifecycle(rawValue: raw) else {
            return localized(
                "diagnostics.unknown.simulatorFrameState",
                defaultValue: "Unknown frame state (\(raw))"
            )
        }
        switch value {
        case .readerAttached:
            return localized("diagnostics.simulator.frame.readerAttached", defaultValue: "Reader attached")
        case .readerMissing:
            return localized("diagnostics.simulator.frame.readerMissing", defaultValue: "Reader missing")
        case .copied:
            return localized("diagnostics.simulator.frame.copied", defaultValue: "Frame copied")
        case .encodeFailed:
            return localized("diagnostics.simulator.frame.encodeFailed", defaultValue: "Frame encode failed")
        case .sent:
            return localized("diagnostics.simulator.frame.sent", defaultValue: "Frame sent")
        case .refused:
            return localized("diagnostics.simulator.frame.refused", defaultValue: "Frame refused by queue")
        case .cachedSent:
            return localized("diagnostics.simulator.frame.cachedSent", defaultValue: "Cached frame sent")
        case .subscriptionReasserted:
            return localized("diagnostics.simulator.frame.subscriptionReasserted", defaultValue: "Subscription reasserted")
        case .received:
            return localized("diagnostics.simulator.frame.received", defaultValue: "Frame received")
        case .staleIgnored:
            return localized("diagnostics.simulator.frame.staleIgnored", defaultValue: "Stale frame ignored")
        case .decodeFailed:
            return localized("diagnostics.simulator.frame.decodeFailed", defaultValue: "Frame decode failed")
        case .imageDecoded:
            return localized("diagnostics.simulator.frame.imageDecoded", defaultValue: "Image decoded")
        case .imageDecodeFailed:
            return localized("diagnostics.simulator.frame.imageDecodeFailed", defaultValue: "Image decode failed")
        case .unknownPanel:
            return localized("diagnostics.simulator.frame.unknownPanel", defaultValue: "Unknown panel")
        }
    }

    private func simulatorInputLifecycleName(_ raw: Int) -> String {
        guard let value = DiagnosticSimulatorInputLifecycle(rawValue: raw) else {
            return localized(
                "diagnostics.unknown.simulatorInputState",
                defaultValue: "Unknown input state (\(raw))"
            )
        }
        switch value {
        case .queued:
            return localized("diagnostics.simulator.input.queued", defaultValue: "Queued")
        case .sent:
            return localized("diagnostics.simulator.input.sent", defaultValue: "Sent")
        case .accepted:
            return localized("diagnostics.simulator.input.accepted", defaultValue: "Accepted")
        case .failed:
            return localized("diagnostics.simulator.input.failed", defaultValue: "Failed")
        case .rejectedLocked:
            return localized("diagnostics.simulator.input.rejectedLocked", defaultValue: "Rejected because locked")
        case .unavailable:
            return localized("diagnostics.simulator.input.unavailable", defaultValue: "Unavailable")
        case .invalidParameters:
            return localized("diagnostics.simulator.input.invalidParameters", defaultValue: "Invalid parameters")
        case .panelMissing:
            return localized("diagnostics.simulator.input.panelMissing", defaultValue: "Panel missing")
        case .featureDisabled:
            return localized("diagnostics.simulator.input.featureDisabled", defaultValue: "Feature disabled")
        case .blockedViewOnly:
            return localized("diagnostics.simulator.input.blockedViewOnly", defaultValue: "Blocked in view-only mode")
        }
    }

    private func simulatorInputKindName(_ raw: Int) -> String {
        guard let value = DiagnosticSimulatorInputKind(rawValue: raw) else {
            return localized(
                "diagnostics.unknown.simulatorInputKind",
                defaultValue: "Unknown input kind (\(raw))"
            )
        }
        switch value {
        case .pointer:
            return localized("diagnostics.simulator.inputKind.pointer", defaultValue: "Pointer")
        case .text:
            return localized("diagnostics.simulator.inputKind.text", defaultValue: "Text")
        case .hardwareButton:
            return localized("diagnostics.simulator.inputKind.hardwareButton", defaultValue: "Hardware button")
        }
    }

    private func simulatorInputDetailName(_ raw: Int, inputKindRaw: Int?) -> String {
        guard let inputKindRaw,
              let inputKind = DiagnosticSimulatorInputKind(rawValue: inputKindRaw) else {
            return String(raw)
        }
        switch inputKind {
        case .pointer:
            return simulatorPointerPhaseName(raw)
        case .text:
            return byteCount(raw)
        case .hardwareButton:
            return simulatorHardwareButtonName(raw)
        }
    }

    private func simulatorPointerPhaseName(_ raw: Int) -> String {
        guard let value = DiagnosticSimulatorPointerPhase(rawValue: raw) else {
            return localized(
                "diagnostics.unknown.simulatorPointerPhase",
                defaultValue: "Unknown pointer phase (\(raw))"
            )
        }
        switch value {
        case .began:
            return localized("diagnostics.simulator.pointer.began", defaultValue: "Began")
        case .moved:
            return localized("diagnostics.simulator.pointer.moved", defaultValue: "Moved")
        case .ended:
            return localized("diagnostics.simulator.pointer.ended", defaultValue: "Ended")
        case .tap:
            return localized("diagnostics.simulator.pointer.tap", defaultValue: "Tap")
        }
    }

    private func simulatorHardwareButtonName(_ raw: Int) -> String {
        guard let value = DiagnosticSimulatorHardwareButtonKind(rawValue: raw) else {
            return localized(
                "diagnostics.unknown.simulatorHardwareButton",
                defaultValue: "Unknown hardware button (\(raw))"
            )
        }
        switch value {
        case .unknown:
            return localized("diagnostics.simulator.button.unknown", defaultValue: "Unknown button")
        case .home:
            return localized("diagnostics.simulator.button.home", defaultValue: "Home")
        case .swipeHome:
            return localized("diagnostics.simulator.button.swipeHome", defaultValue: "Swipe Home")
        case .appSwitcher:
            return localized("diagnostics.simulator.button.appSwitcher", defaultValue: "App Switcher")
        case .lock:
            return localized("diagnostics.simulator.button.lock", defaultValue: "Lock")
        case .siri:
            return localized("diagnostics.simulator.button.siri", defaultValue: "Siri")
        case .sideButton:
            return localized("diagnostics.simulator.button.sideButton", defaultValue: "Side button")
        case .power:
            return localized("diagnostics.simulator.button.power", defaultValue: "Power")
        case .volumeUp:
            return localized("diagnostics.simulator.button.volumeUp", defaultValue: "Volume up")
        case .volumeDown:
            return localized("diagnostics.simulator.button.volumeDown", defaultValue: "Volume down")
        case .action:
            return localized("diagnostics.simulator.button.action", defaultValue: "Action")
        case .watchSideButton:
            return localized("diagnostics.simulator.button.watchSideButton", defaultValue: "Watch side button")
        }
    }

    private func simulatorOwnershipName(_ raw: Int) -> String {
        guard let value = DiagnosticSimulatorOwnershipState(rawValue: raw) else {
            return localized(
                "diagnostics.unknown.simulatorOwner",
                defaultValue: "Unknown owner state (\(raw))"
            )
        }
        switch value {
        case .unowned:
            return localized("diagnostics.simulator.owner.unowned", defaultValue: "Unowned")
        case .currentConnection:
            return localized("diagnostics.simulator.owner.currentConnection", defaultValue: "Current connection")
        case .otherConnection:
            return localized("diagnostics.simulator.owner.otherConnection", defaultValue: "Other connection")
        case .pendingHandshake:
            return localized("diagnostics.simulator.owner.pendingHandshake", defaultValue: "Pending handshake")
        case .unknown:
            return localized("diagnostics.simulator.owner.unknown", defaultValue: "Unknown")
        }
    }

    private func simulatorCoordinateStateName(_ raw: Int) -> String {
        guard let value = DiagnosticSimulatorCoordinateState(rawValue: raw) else {
            return localized(
                "diagnostics.unknown.simulatorCoordinateState",
                defaultValue: "Unknown coordinate state (\(raw))"
            )
        }
        switch value {
        case .mapped:
            return localized("diagnostics.simulator.coordinate.mapped", defaultValue: "Mapped")
        case .outsideImage:
            return localized("diagnostics.simulator.coordinate.outsideImage", defaultValue: "Outside image")
        case .viewOnlyBlocked:
            return localized("diagnostics.simulator.coordinate.viewOnlyBlocked", defaultValue: "View-only blocked")
        case .zeroImage:
            return localized("diagnostics.simulator.coordinate.zeroImage", defaultValue: "Missing image geometry")
        }
    }

    private func normalizedCoordinate(_ raw: Int) -> String {
        String(format: "%.4f", Double(raw) / 10_000.0)
    }

    private func duration(_ milliseconds: UInt32) -> String {
        guard milliseconds >= 1_000 else {
            return localized(
                "diagnostics.duration.milliseconds",
                defaultValue: "\(Int(milliseconds)) ms"
            )
        }
        if milliseconds.isMultiple(of: 1_000) {
            return secondCount(Int(milliseconds / 1_000))
        }
        let seconds = milliseconds / 1_000
        let remainder = milliseconds % 1_000
        let value = "\(seconds).\(paddedMilliseconds(remainder))"
        return localized(
            "diagnostics.duration.fractionalSeconds",
            defaultValue: "\(value) seconds"
        )
    }

    private func secondCount(_ value: Int) -> String {
        if value == 1 {
            return localized("diagnostics.duration.seconds", defaultValue: "\(value) second")
        }
        return localized("diagnostics.duration.seconds", defaultValue: "\(value) seconds")
    }

    private func byteCount(_ value: Int) -> String {
        if value == 1 {
            return localized("diagnostics.count.bytes", defaultValue: "\(value) byte")
        }
        return localized("diagnostics.count.bytes", defaultValue: "\(value) bytes")
    }

    private func pointCount(_ value: Int) -> String {
        if value == 1 {
            return localized("diagnostics.count.points", defaultValue: "\(value) point")
        }
        return localized("diagnostics.count.points", defaultValue: "\(value) points")
    }

    private func paddedMilliseconds(_ value: UInt32) -> String {
        if value < 10 { return "00\(value)" }
        if value < 100 { return "0\(value)" }
        return String(value)
    }

    private func label(for key: String) -> String {
        switch key {
        case "surface": localized("diagnostics.field.surface", defaultValue: "Surface")
        case "transport": localized("diagnostics.field.transport", defaultValue: "Transport")
        case "failure": localized("diagnostics.field.failure", defaultValue: "Failure")
        case "attempt": localized("diagnostics.field.attempt", defaultValue: "Attempt")
        case "retry_delay": localized("diagnostics.field.retryDelay", defaultValue: "Retry delay")
        case "initiator": localized("diagnostics.field.initiator", defaultValue: "Initiator")
        case "application_error_code": localized("diagnostics.field.applicationErrorCode", defaultValue: "Application error code")
        case "session": localized("diagnostics.field.session", defaultValue: "Session")
        case "phase": localized("diagnostics.field.phase", defaultValue: "Phase")
        case "network": localized("diagnostics.field.network", defaultValue: "Network")
        case "trigger": localized("diagnostics.field.trigger", defaultValue: "Trigger")
        case "state": localized("diagnostics.field.state", defaultValue: "State")
        case "purpose": localized("diagnostics.field.purpose", defaultValue: "Purpose")
        case "path": localized("diagnostics.field.path", defaultValue: "Path")
        case "operation": localized("diagnostics.field.operation", defaultValue: "Operation")
        case "duration": localized("diagnostics.field.duration", defaultValue: "Duration")
        case "lag": localized("diagnostics.field.lag", defaultValue: "Lag")
        case "silent_for": localized("diagnostics.field.silentFor", defaultValue: "Silent for")
        case "composer_visible": localized("diagnostics.field.composerVisible", defaultValue: "Composer visible")
        case "draft_size": localized("diagnostics.field.draftSize", defaultValue: "Draft size")
        case "draft_empty": localized("diagnostics.field.draftEmpty", defaultValue: "Draft empty")
        case "focused": localized("diagnostics.field.focused", defaultValue: "Focused")
        case "composer_active": localized("diagnostics.field.composerActive", defaultValue: "Composer active")
        case "first_responder": localized("diagnostics.field.firstResponder", defaultValue: "First responder")
        case "keyboard_height": localized("diagnostics.field.keyboardHeight", defaultValue: "Keyboard height")
        case "terminal_input_focused": localized("diagnostics.field.terminalInputFocused", defaultValue: "Terminal input focused")
        case "local_sequence": localized("diagnostics.field.localSequence", defaultValue: "Local sequence")
        case "remote_sequence": localized("diagnostics.field.remoteSequence", defaultValue: "Remote sequence")
        case "delivered_sequence": localized("diagnostics.field.deliveredSequence", defaultValue: "Delivered sequence")
        case "next_sequence": localized("diagnostics.field.nextSequence", defaultValue: "Next sequence")
        case "stage": localized("diagnostics.field.stage", defaultValue: "Stage")
        case "owner": localized("diagnostics.field.owner", defaultValue: "Owner")
        case "previous_owner": localized("diagnostics.field.previousOwner", defaultValue: "Previous owner")
        case "frame_sequence": localized("diagnostics.field.frameSequence", defaultValue: "Frame sequence")
        case "payload_size": localized("diagnostics.field.payloadSize", defaultValue: "Payload size")
        case "input": localized("diagnostics.field.input", defaultValue: "Input")
        case "input_detail": localized("diagnostics.field.inputDetail", defaultValue: "Input detail")
        case "active_sessions": localized("diagnostics.field.activeSessions", defaultValue: "Active sessions")
        case "count": localized("diagnostics.field.count", defaultValue: "Count")
        case "value": localized("diagnostics.field.value", defaultValue: "Value")
        case "method": localized("diagnostics.field.method", defaultValue: "Method")
        case "action": localized("diagnostics.field.action", defaultValue: "Action")
        case "tab": localized("diagnostics.field.tab", defaultValue: "Tab")
        case "scope": localized("diagnostics.field.scope", defaultValue: "Scope")
        case "change": localized("diagnostics.field.change", defaultValue: "Change")
        case "route": localized("diagnostics.field.route", defaultValue: "Route")
        case "style": localized("diagnostics.field.style", defaultValue: "Style")
        case "reason": localized("diagnostics.field.reason", defaultValue: "Reason")
        case "outcome": localized("diagnostics.field.outcome", defaultValue: "Outcome")
        case "editable_focused": localized("diagnostics.field.editableFocused", defaultValue: "Editable focused")
        case "created": localized("diagnostics.field.created", defaultValue: "Created")
        case "public_paths": localized("diagnostics.field.publicPaths", defaultValue: "Public paths")
        case "private_fallback_paths":
            localized(
                "diagnostics.field.privateFallbackPaths",
                defaultValue: "Private fallback paths"
            )
        case "join": localized("diagnostics.field.join", defaultValue: "Join")
        case "configured_addresses":
            localized(
                "diagnostics.field.configuredAddresses",
                defaultValue: "Configured addresses"
            )
        case "hints": localized("diagnostics.field.hints", defaultValue: "Hints")
        case "leg": localized("diagnostics.field.leg", defaultValue: "Leg")
        case "panel": localized("diagnostics.field.panel", defaultValue: "Panel")
        case "x": localized("diagnostics.field.x", defaultValue: "X")
        case "y": localized("diagnostics.field.y", defaultValue: "Y")
        case "mapping": localized("diagnostics.field.mapping", defaultValue: "Mapping")
        case "detail_1": localized("diagnostics.field.detail1", defaultValue: "Detail 1")
        case "detail_2": localized("diagnostics.field.detail2", defaultValue: "Detail 2")
        case "detail_3": localized("diagnostics.field.detail3", defaultValue: "Detail 3")
        default:
            key
        }
    }

    private func localized(
        _ key: StaticString,
        defaultValue: String.LocalizationValue
    ) -> String {
        localization.string(key, defaultValue: defaultValue)
    }
}
