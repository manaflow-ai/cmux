public import CmuxNextDevices
public import CmuxScreenKit
public import Foundation
import Observation

// The device hub's side of Mac Screen (docs/device-hub/PROTOCOL.md): the
// decisions the viewer, the host and Settings > Devices share, kept free of
// UI so tests read them directly.

/// This device signs its Session DO handshake and its DTLS fingerprints with
/// its device key (the Secure Enclave identity the hub registered).
extension DeviceIdentity: ScreenTicketSigner {
    nonisolated public func deviceHeaders(for url: URL) async throws -> [String: String] {
        try DeviceRequestSigner(identity: self).headers(method: "GET", pathAndQuery: DeviceRequestSigner.pathAndQuery(of: url),
                                                        body: nil)
    }
}

extension DeviceHubICEServer {
    /// The WebRTC form of this ICE server.
    nonisolated var config: ICEServerConfig { ICEServerConfig(urls: urls, username: username, credential: credential) }
}

/// Why the hub refused a viewer's request, as the viewer's card says it.
public nonisolated enum MacScreenHubRefusal: Equatable, Sendable {
    /// The host's permission for this device is None.
    case permissionNone
    /// The permission is View only and the request was Full control.
    case scopeExceeds
    /// The host is not connected to the hub.
    case hostOffline
    /// The host does not share Mac Screen.
    case notShared
    /// The host was removed from the user's devices (or is unknown).
    case notFound
    /// This device is not signed in to the hub.
    case notSignedIn
    /// Anything else (a transport failure, a server error).
    case other

    /// Whether Try Again makes sense: not for a device that left the user's devices.
    public var canRetry: Bool { self != .notFound }

    /// The refusal for a failed `POST /v1/sessions`.
    public init(_ error: DeviceHubError) {
        switch error.code {
        case .some(.permissionNone): self = .permissionNone
        case .some(.scopeExceedsPermission): self = .scopeExceeds
        case .some(.hostOffline): self = .hostOffline
        case .some(.notShared): self = .notShared
        case .some(.notFound), .some(.deviceRemoved): self = .notFound
        case .some(.unauthorized): self = .notSignedIn
        default:
            if case .notSignedIn = error { self = .notSignedIn } else if case .notConfigured = error { self = .notSignedIn } else { self = .other }
        }
    }
}

/// A viewer tab's progress with the hub, before and around the stream.
public nonisolated enum MacScreenHubPhase: Equatable, Sendable {
    /// Restored, opened by automation, or ended: the Connect card (View / Control).
    case idle
    /// The request is on its way.
    case requesting(SessionScope)
    /// The host's person decides (permission Ask).
    case waitingForApproval(sessionID: String, scope: SessionScope)
    /// Approved: the ticket is on its way.
    case approved(sessionID: String, scope: SessionScope)
    /// The ticket came: the stream runs (`ScreenSession` says how far it got).
    case streaming(sessionID: String, scope: SessionScope)
    /// The stream failed (its card says why); the hub hears `failed` unless its own reason comes first.
    case streamFailed(sessionID: String, scope: SessionScope)
    /// The host's person said Deny.
    case declined(SessionScope)
    case refused(MacScreenHubRefusal, requested: SessionScope)
    /// The hub ended the session at once (`session.revoked`): permission lowered, a device removed, sharing off.
    case revoked(reason: String?)
    /// The session ended (`session.ended`, or Disconnect here).
    case ended(reason: String?)

    /// The session this phase belongs to, if any.
    public var sessionID: String? {
        switch self {
        case let .waitingForApproval(id, _), let .approved(id, _), let .streaming(id, _), let .streamFailed(id, _): id
        default: nil
        }
    }

    /// Waiting for the host or the ticket (a push can still arrive for it).
    public var isPending: Bool {
        switch self {
        case .requesting, .waitingForApproval, .approved: true
        default: false
        }
    }

    /// The scope a running stream has; nil otherwise.
    public var streamingScope: SessionScope? {
        if case let .streaming(_, scope) = self { return scope }
        return nil
    }
}

/// Why a session was revoked or ended, as people read it. The hub's reasons
/// are authoritative (PROTOCOL.md): `permission_revoked`,
/// `device_removed:viewer|host`, `sharing_off`, `host_stopped`,
/// `viewer_disconnected`, `signed_out`, `peer_offline`; older servers sent
/// `permission_changed` and `device_removed`, and a dropped socket `bye` or `closed`.
public nonisolated enum MacScreenEndReason: Equatable, Sendable {
    case permissionRevoked
    /// The host changed this Mac's access and it still has some (re-granted after a revocation).
    case accessChanged
    /// This Mac (the viewer) was removed from the user's devices.
    case viewerRemoved
    /// The host was removed from the user's devices.
    case hostRemoved
    /// A device of the session was removed (a server that does not say which).
    case deviceRemoved
    case sharingOff
    case hostStopped
    case viewerDisconnected
    case signedOut
    /// The other device lost its connection to the hub.
    case peerOffline
    /// The stream could not start (or dropped) on one side.
    case failed
    /// The host did not answer the request within five minutes.
    case expired
    /// The hub could not set up the session the host approved.
    case approveFailed
    case other

    public init(_ reason: String?) {
        switch reason ?? "" {
        case "permission_revoked", "permission_changed", "host_revoked": self = .permissionRevoked
        case "device_removed:viewer": self = .viewerRemoved
        case "device_removed:host": self = .hostRemoved
        case "device_removed": self = .deviceRemoved
        case "sharing_off": self = .sharingOff
        case "host_stopped": self = .hostStopped
        case "viewer_disconnected", "tab_closed": self = .viewerDisconnected
        case let text where text.hasPrefix("signed_out"): self = .signedOut
        case let text where text.hasPrefix("peer_offline"): self = .peerOffline
        case "failed": self = .failed
        case "expired": self = .expired
        case "approve_failed": self = .approveFailed
        default: self = .other
        }
    }

    /// Whether Connect Again makes sense: not for a device that left the user's devices.
    var canReconnect: Bool {
        switch self {
        case .hostRemoved, .viewerRemoved, .deviceRemoved: false
        default: true
        }
    }

    /// The viewer lost its access (a card titled Access Removed), rather than a session that ended.
    var removesAccess: Bool {
        switch self {
        case .permissionRevoked, .viewerRemoved, .hostRemoved, .deviceRemoved: true
        default: false
        }
    }

    /// The viewer's card text, naming the host device (never "this Mac" for it).
    func text(host: String) -> String {
        switch self {
        case .permissionRevoked: String(format: L.t("macScreen.hub.reason.revoked", "%@ removed this Mac’s access to its screen."), host)
        case .accessChanged: String(format: L.t("macScreen.hub.reason.accessChanged", "%@ changed this Mac’s access. Connect again to continue."), host)
        case .viewerRemoved: L.t("macScreen.hub.reason.viewerRemoved", "This Mac was removed from your devices.")
        case .hostRemoved: String(format: L.t("macScreen.hub.reason.hostRemoved", "%@ was removed from your devices."), host)
        case .deviceRemoved: L.t("macScreen.hub.reason.removed", "A device was removed from your devices.")
        case .sharingOff: String(format: L.t("macScreen.hub.reason.sharingOffNamed", "%@ turned off Mac Screen."), host)
        case .hostStopped: String(format: L.t("macScreen.hub.reason.hostStoppedNamed", "%@ stopped sharing its screen."), host)
        case .viewerDisconnected: L.t("macScreen.hub.reason.viewer", "You disconnected.")
        case .signedOut: L.t("macScreen.hub.reason.signedOutOrQuit", "A Mac in this session signed out of cmux or quit it.")
        case .peerOffline: String(format: L.t("macScreen.hub.reason.offline", "%@ went offline."), host)
        case .failed: L.t("macScreen.hub.reason.failed", "The screen stream could not start.")
        case .approveFailed: String(format: L.t("macScreen.hub.reason.approveFailed", "%@ allowed the session, but it couldn’t start. Try again."), host)
        case .expired: String(format: L.t("macScreen.hub.reason.expired", "%@ did not answer in time."), host)
        case .other: L.t("macScreen.hub.reason.other", "The session ended.")
        }
    }
}

/// The `/end` reasons this app sends (metadata only: they land in the audit log).
public nonisolated enum MacScreenHubReason: String, Sendable {
    /// The host's Stop Sharing.
    case hostStopped = "host_stopped"
    /// Disconnect, or the viewer's tab closed.
    case viewerDisconnected = "viewer_disconnected"
    case signedOut = "signed_out"
    /// A newer session of the same pair took over.
    case replaced
    /// The stream could not start.
    case failed
}

/// The host's answers to a request (the approval prompt's buttons).
public nonisolated enum MacScreenApprovalChoice: String, CaseIterable, Sendable {
    case deny, once, alwaysView, alwaysFull

    /// What the hub is told for a request of `requested`: the decision, the
    /// session's scope (a decision may lower Full to View, never raise it),
    /// and a permission to store afterwards when the decision alone cannot
    /// (Always Allow Full Control on a View request: the session stays View,
    /// the permission becomes Full).
    public func answer(requested: SessionScope) -> (decision: SessionDecision, scope: SessionScope, thenPermission: DeviceScope?) {
        switch self {
        case .deny: return (SessionDecision.deny, requested, nil)
        case .once: return (SessionDecision.once, requested, nil)
        case .alwaysView: return (SessionDecision.always, SessionScope.view, nil)
        case .alwaysFull:
            if requested == .full { return (SessionDecision.always, SessionScope.full, nil) }
            return (SessionDecision.always, SessionScope.view, DeviceScope.full)
        }
    }

    /// The prompt's button title.
    var title: String {
        switch self {
        case .deny: L.t("macScreen.approval.deny", "Deny")
        case .once: L.t("macScreen.approval.once", "Allow Once")
        case .alwaysView: L.t("macScreen.approval.alwaysView", "Always Allow View Only")
        case .alwaysFull: L.t("macScreen.approval.alwaysFull", "Always Allow Full Control")
        }
    }
}

/// Mac Screen access for one device on one Mac (the Devices and Mac Screen pickers).
public nonisolated struct MacScreenAccess: Sendable, Equatable {
    public let scope: DeviceScope

    public init(_ scope: DeviceScope) { self.scope = scope }

    /// The picker's value for a scope (the protocol's own name).
    public var value: String { scope.rawValue }

    /// The scope a picker value names; nil for anything else.
    public init?(value: String) {
        guard let scope = DeviceScope(rawValue: value) else { return nil }
        self.scope = scope
    }

    /// Every choice, in the pickers' order.
    public static let all: [MacScreenAccess] = [.init(.none), .init(.ask), .init(.view), .init(.full)]

    public var title: String {
        switch scope {
        case .none: L.t("macScreen.access.none", "None")
        case .ask: L.t("macScreen.access.ask", "Ask")
        case .view: L.t("macScreen.access.view", "View Only")
        case .full: L.t("macScreen.access.full", "Full Control")
        }
    }

    /// Whether this device may ask the host for a session: not at None, which
    /// means the host blocked it (the hub refuses the request without a prompt).
    public var allowsRequests: Bool { scope != .none }

    /// What a session of `requested` gets without a prompt: the scope, nil
    /// when it asks first (Ask) or is refused (None, or Full under View).
    public func grants(_ requested: SessionScope) -> Bool {
        switch scope {
        case .none, .ask: false
        case .view: requested == .view
        case .full: true
        }
    }
}

extension SessionScope {
    /// "View Only" or "Full Control".
    nonisolated var title: String {
        switch self {
        case .view: L.t("macScreen.scope.view", "View Only")
        case .full: L.t("macScreen.scope.full", "Full Control")
        }
    }
}

/// The device hub as the home page observes it (``MacScreenPages/hub`` is a plain property).
@MainActor @Observable
final class MacScreenHubBox {
    var hub: DeviceHub?
    var configured = false
}
