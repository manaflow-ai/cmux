import Foundation

/// Decodes a ``DiagnosticEvent`` into privacy-safe text for reports and
/// telemetry sinks.
///
/// The event recorder deliberately stores only bounded integers. Formatting
/// happens here, after recording, so hot transport paths stay allocation-free
/// while every exported title and payload explains itself without a decoder.
/// Stable machine names remain available through the `name(_:)` overloads for
/// Sentry fingerprints, tags, and search attributes.
public enum DiagnosticEventPresentation {
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
    public static func name(_ code: DiagnosticEventCode) -> String {
        String(describing: code)
    }

    /// The stable machine name of a failure kind.
    public static func name(_ kind: DiagnosticFailureKind) -> String {
        String(describing: kind)
    }

    /// The stable machine name of a transport kind.
    public static func name(_ kind: DiagnosticTransportKind) -> String {
        String(describing: kind)
    }

    /// The stable machine name of a path kind.
    public static func name(_ kind: DiagnosticPathKind) -> String {
        String(describing: kind)
    }

    /// The stable machine name of a session lifecycle kind.
    public static func name(_ kind: DiagnosticSessionLifecycleKind) -> String {
        String(describing: kind)
    }

    /// The stable machine name of an app lifecycle phase.
    public static func name(_ phase: DiagnosticAppLifecyclePhase) -> String {
        String(describing: phase)
    }

    /// The stable machine name of a runtime role.
    public static func name(_ role: DiagnosticRuntimeRole) -> String {
        String(describing: role)
    }

    /// Human-readable name of a diagnostic failure category.
    public static func displayName(_ kind: DiagnosticFailureKind) -> String {
        switch kind {
        case .none: "No failure"
        case .offline: "Offline"
        case .timedOut: "Timed out"
        case .connectionRefused: "Connection refused"
        case .hostUnreachable: "Host unreachable"
        case .permissionDenied: "Permission denied"
        case .dnsFailed: "DNS lookup failed"
        case .secureChannelFailed: "Secure channel failed"
        case .unsupportedRoute: "Unsupported route"
        case .noRoute: "No route available"
        case .credentialUnavailable: "Credentials unavailable"
        case .policyUnavailable: "Relay policy unavailable"
        case .endpointUnavailable: "Iroh endpoint unavailable"
        case .identityMismatch: "Host identity mismatch"
        case .admissionDenied: "Client admission denied"
        case .authorizationFailed: "Authorization failed"
        case .accountMismatch: "Account mismatch"
        case .protocolViolation: "Protocol violation"
        case .connectionClosed: "Connection closed"
        case .superseded: "Superseded by a newer attempt"
        case .cancelled: "Cancelled"
        case .transportIdleTimedOut: "Transport idle timed out"
        case .admissionLeaseExpired: "Admission lease expired"
        case .admissionRevalidationFailed: "Admission revalidation failed"
        case .sendQueueOverflow: "Send queue overflow"
        case .routeGated: "Route already connecting"
        case .unknown: "Unknown failure"
        }
    }

    /// Human-readable name of a transport category.
    public static func displayName(_ kind: DiagnosticTransportKind) -> String {
        switch kind {
        case .unknown: "Unknown transport"
        case .iroh: "Iroh"
        case .tailscale: "Tailscale"
        case .websocket: "WebSocket"
        case .debugLoopback: "Debug loopback"
        }
    }

    /// Human-readable name of a selected network path.
    public static func displayName(_ kind: DiagnosticPathKind) -> String {
        switch kind {
        case .unknown: "Unknown path"
        case .direct: "Direct"
        case .relay: "Relay"
        case .privateNetwork: "Private network"
        case .loopback: "Loopback"
        }
    }

    /// Human-readable name of a transport-session lifecycle state.
    public static func displayName(_ kind: DiagnosticSessionLifecycleKind) -> String {
        switch kind {
        case .established: "Established"
        case .controlOwnerReleased: "Control owner released"
        case .controlReadFailed: "Control read failed"
        case .controlWriteFailed: "Control write failed"
        case .remoteClosed: "Remote closed"
        case .closedSessionEvicted: "Closed session evicted"
        case .applicationLaneFailed: "Application lane failed"
        case .runtimeDeactivated: "Runtime deactivated"
        case .runtimeReconfigured: "Runtime reconfigured"
        case .explicitlyInvalidated: "Explicitly invalidated"
        case .allPathsClosed: "All paths closed"
        }
    }

    /// Human-readable name of an app lifecycle phase.
    public static func displayName(_ phase: DiagnosticAppLifecyclePhase) -> String {
        switch phase {
        case .background: "Background"
        case .active: "Active"
        case .inactive: "Inactive"
        }
    }

    /// Human-readable name of a report's producing runtime.
    public static func displayName(_ role: DiagnosticRuntimeRole) -> String {
        switch role {
        case .unspecified: "Unspecified runtime"
        case .mobileClient: "iOS client"
        case .macHost: "Mac host"
        case .broker: "Broker"
        case .relay: "Relay"
        }
    }

    /// Decodes an event's payload slots according to its documented schema.
    /// Unknown enum values retain their integer inside an explanatory label so
    /// a newer writer still produces useful text on an older reader.
    public static func describe(_ event: DiagnosticEvent) -> DescribedEvent {
        var fields: [Field] = []
        if let surface = event.surface {
            fields.append(Field(key: "surface", value: String(surface)))
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
            fields.append(decodeC(c, code: event.code))
        }
        return DescribedEvent(name: title(for: event.code), fields: fields)
    }

    /// Renders one event as a standalone human-readable sentence fragment.
    public static func summary(_ event: DiagnosticEvent) -> String {
        summary(describe(event))
    }

    /// Renders an already-described event as a title followed by labeled fields.
    public static func summary(_ described: DescribedEvent) -> String {
        guard !described.fields.isEmpty else { return described.name }
        let details = described.fields.map { field in
            "\(label(for: field.key)): \(field.value)"
        }
        return "\(described.name) (\(details.joined(separator: ", ")))"
    }

    /// The failure kind carried in an event's `b` slot, when applicable.
    public static func failureKind(of event: DiagnosticEvent) -> DiagnosticFailureKind? {
        guard codesWithFailureB.contains(event.code), let b = event.b else { return nil }
        return DiagnosticFailureKind(rawValue: b)
    }

    /// The transport kind carried in an event's `a` slot, when applicable.
    public static func transportKind(of event: DiagnosticEvent) -> DiagnosticTransportKind? {
        guard codesWithTransportA.contains(event.code), let a = event.a else { return nil }
        return DiagnosticTransportKind(rawValue: a)
    }

    /// Event codes whose `b` slot carries a ``DiagnosticFailureKind``.
    static let codesWithFailureB: Set<DiagnosticEventCode> = [
        .pairFail, .transportDialFailed, .recoveryFailed, .endpointFailed,
        .relayPolicyRefreshFailed, .sessionClosed, .routeUnavailable,
        .discoveryFailed, .admissionFailed, .hostAuthenticationFailed,
        .rpcFailed, .transportCloseAttribution,
    ]

    /// Event codes whose `a` slot carries a ``DiagnosticTransportKind``.
    static let codesWithTransportA: Set<DiagnosticEventCode> = [
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

    private static func title(for code: DiagnosticEventCode) -> String {
        switch code {
        case .connect: "Connection attempt started"
        case .pairOk: "Pairing succeeded"
        case .pairFail: "Pairing failed"
        case .renderGridLag: "Render grid lagged"
        case .livenessResubscribe: "Silent event stream resubscribed"
        case .streamEnded: "Event stream ended"
        case .inputSeqBehind: "Terminal input acknowledgements fell behind"
        case .byteGap: "Terminal byte gap detected"
        case .error: "Unclassified transport error"
        case .pairUnreachable: "Pairing skipped while offline"
        case .composerPresentedChanged: "Composer visibility changed"
        case .composerInputTextChanged: "Composer draft changed"
        case .composerViewAppear: "Composer appeared"
        case .composerViewDisappear: "Composer disappeared"
        case .composerFieldFocusChanged: "Composer focus changed"
        case .composerActiveTransition: "Composer activation changed"
        case .composerKeyboardToggleWhilePresented:
            "Keyboard toggled while composer was open"
        case .transportDialStarted: "Transport dial started"
        case .transportDialConnected: "Transport connected"
        case .transportDialFailed: "Transport dial failed"
        case .hostAuthenticated: "Host authenticated"
        case .rpcReady: "RPC session ready"
        case .recoveryStarted: "Connection recovery started"
        case .recoverySucceeded: "Connection recovery succeeded"
        case .recoveryFailed: "Connection recovery failed"
        case .endpointStarting: "Iroh endpoint starting"
        case .endpointActive: "Iroh endpoint active"
        case .endpointStopped: "Iroh endpoint stopped"
        case .endpointFailed: "Iroh endpoint failed"
        case .relayPolicyRefreshStarted: "Relay policy refresh started"
        case .relayPolicyRefreshSucceeded: "Relay policy refreshed"
        case .relayPolicyRefreshFailed: "Relay policy refresh failed"
        case .selectedPathChanged: "Selected network path changed"
        case .sessionClosed: "Transport session closed"
        case .routeUnavailable: "No usable transport route"
        case .retryScheduled: "Retry scheduled"
        case .discoveryStarted: "Iroh route discovery started"
        case .discoverySucceeded: "Iroh route discovery succeeded"
        case .discoveryFailed: "Iroh route discovery failed"
        case .admissionSucceeded: "Client admitted"
        case .admissionFailed: "Client admission failed"
        case .hostAuthenticationFailed: "Host authentication failed"
        case .rpcFailed: "RPC session failed"
        case .transportSessionLifecycle: "Transport session state changed"
        case .appLifecycleChanged: "App lifecycle changed"
        case .reachabilityChanged: "Network reachability changed"
        case .transportCloseAttribution: "Transport close attributed"
        case .transportPathEvent: "Transport path changed"
        }
    }

    private static func decodeA(_ raw: Int, code: DiagnosticEventCode) -> Field {
        if codesWithTransportA.contains(code) {
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
            return Field(key: "draft_size", value: count(raw, singular: "byte"))
        case .composerFieldFocusChanged:
            return Field(key: "focused", value: booleanName(raw))
        case .composerActiveTransition:
            return Field(key: "composer_active", value: booleanName(raw))
        case .composerKeyboardToggleWhilePresented:
            return Field(key: "terminal_input_focused", value: booleanName(raw))
        default:
            return Field(key: "detail_1", value: String(raw))
        }
    }

    private static func decodeB(_ raw: Int, code: DiagnosticEventCode) -> Field {
        if codesWithFailureB.contains(code) {
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
        default:
            return Field(key: "detail_2", value: String(raw))
        }
    }

    private static func decodeMilliseconds(
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
            return Field(key: "keyboard_height", value: "\(raw) points")
        default:
            return Field(key: "duration", value: duration(raw))
        }
    }

    private static func decodeC(_ raw: Int, code: DiagnosticEventCode) -> Field {
        switch code {
        case .transportDialStarted, .transportDialConnected, .transportDialFailed:
            return Field(key: "attempt", value: String(raw))
        case .sessionClosed, .transportSessionLifecycle,
             .transportCloseAttribution, .transportPathEvent:
            return Field(key: "session", value: String(raw))
        case .composerActiveTransition:
            return Field(key: "terminal_input_focused", value: booleanName(raw))
        default:
            return Field(key: "detail_3", value: String(raw))
        }
    }

    private static func failureName(_ raw: Int) -> String {
        guard let value = DiagnosticFailureKind(rawValue: raw) else {
            return "Unknown failure (\(raw))"
        }
        return displayName(value)
    }

    private static func transportName(_ raw: Int) -> String {
        guard let value = DiagnosticTransportKind(rawValue: raw) else {
            return "Unknown transport (\(raw))"
        }
        return displayName(value)
    }

    private static func pathName(_ raw: Int) -> String {
        guard let value = DiagnosticPathKind(rawValue: raw) else {
            return "Unknown path (\(raw))"
        }
        return displayName(value)
    }

    private static func sessionLifecycleName(_ raw: Int) -> String {
        guard let value = DiagnosticSessionLifecycleKind(rawValue: raw) else {
            return "Unknown session state (\(raw))"
        }
        return displayName(value)
    }

    private static func appLifecycleName(_ raw: Int) -> String {
        guard let value = DiagnosticAppLifecyclePhase(rawValue: raw) else {
            return "Unknown app phase (\(raw))"
        }
        return displayName(value)
    }

    private static func sessionPurposeName(_ raw: Int) -> String {
        guard let byte = UInt8(exactly: raw),
              let purpose = CmxTransportSessionPurpose(rawValue: byte)
        else {
            return "Unknown session purpose (\(raw))"
        }
        switch purpose {
        case .foregroundControl: return "Foreground control"
        case .backgroundControl: return "Background control"
        case .probe: return "Connection probe"
        case .featureLane: return "Feature lane"
        }
    }

    private static func responderName(_ raw: Int) -> String {
        guard let identity = InputResponderIdentity(rawValue: raw) else {
            return "Unknown responder (\(raw))"
        }
        switch identity {
        case .none: return "None"
        case .terminalInputProxy: return "Terminal input"
        case .ghosttySurface: return "Terminal surface"
        case .uiTextField: return "Text field"
        case .uiTextView: return "Text view"
        case .other: return "Other responder"
        }
    }

    private static func booleanName(_ raw: Int) -> String {
        switch raw {
        case 0: "No"
        case 1: "Yes"
        default: "Unknown state (\(raw))"
        }
    }

    private static func reachabilityName(_ raw: Int) -> String {
        switch raw {
        case 0: "Offline"
        case 1: "Online"
        default: "Unknown network state (\(raw))"
        }
    }

    private static func recoveryTriggerName(_ raw: Int) -> String {
        switch raw {
        case 1: "Network changed"
        case 2: "Manual retry"
        case 3: "Presence notification"
        case 4: "App returned to foreground"
        case 5: "Liveness check failed"
        case 6: "Event stream ended"
        case 7: "Subscription failed to start"
        case 8: "Transport write timed out"
        case 9: "Automatic retry delay expired"
        default: "Unknown recovery trigger (\(raw))"
        }
    }

    private static func closeInitiatorName(_ raw: Int) -> String {
        switch raw {
        case 0: "Unknown initiator"
        case 1: "Local app"
        case 2: "Remote peer"
        case 3: "Timed out"
        default: "Unknown close initiator (\(raw))"
        }
    }

    private static func pathEventName(_ raw: Int) -> String {
        switch raw {
        case 1: "Opened"
        case 2: "Closed"
        case 3: "Selected"
        case 4: "Lagged"
        default: "Unknown path operation (\(raw))"
        }
    }

    private static func duration(_ milliseconds: UInt32) -> String {
        guard milliseconds >= 1_000 else { return "\(milliseconds) ms" }
        let seconds = Double(milliseconds) / 1_000
        if milliseconds.isMultiple(of: 1_000) {
            let whole = milliseconds / 1_000
            return count(Int(whole), singular: "second")
        }
        return String(
            format: "%.3f seconds",
            locale: Locale(identifier: "en_US_POSIX"),
            seconds
        )
    }

    private static func count(_ value: Int, singular: String) -> String {
        "\(value) \(value == 1 ? singular : singular + "s")"
    }

    private static func label(for key: String) -> String {
        switch key {
        case "surface": "Surface"
        case "transport": "Transport"
        case "failure": "Failure"
        case "attempt": "Attempt"
        case "retry_delay": "Retry delay"
        case "initiator": "Initiator"
        case "application_error_code": "Application error code"
        case "session": "Session"
        case "phase": "Phase"
        case "network": "Network"
        case "trigger": "Trigger"
        case "state": "State"
        case "purpose": "Purpose"
        case "path": "Path"
        case "operation": "Operation"
        case "duration": "Duration"
        case "lag": "Lag"
        case "silent_for": "Silent for"
        case "composer_visible": "Composer visible"
        case "draft_size": "Draft size"
        case "draft_empty": "Draft empty"
        case "focused": "Focused"
        case "composer_active": "Composer active"
        case "first_responder": "First responder"
        case "keyboard_height": "Keyboard height"
        case "terminal_input_focused": "Terminal input focused"
        case "local_sequence": "Local sequence"
        case "remote_sequence": "Remote sequence"
        case "delivered_sequence": "Delivered sequence"
        case "next_sequence": "Next sequence"
        case "detail_1": "Detail 1"
        case "detail_2": "Detail 2"
        case "detail_3": "Detail 3"
        default:
            key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
