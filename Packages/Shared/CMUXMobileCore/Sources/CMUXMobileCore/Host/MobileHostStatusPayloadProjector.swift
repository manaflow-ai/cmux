import Foundation

/// Builds the `mobile.host.status` reply bodies from a route projection plus the
/// Mac's resolved identity strings.
///
/// This is a pure value projector: it holds the already-resolved inputs (the
/// JSON-shaped routes, and for the identity reply the Mac's stable identity and
/// build strings) and produces the `[String: Any]` reply bodies. The identity
/// values originate app-side (`MobileHostIdentity` is `UserDefaults`-backed and
/// `MobileHostBuildIdentity` reads `Bundle.main`), so the app resolves them and
/// hands the `String?` results to this projector rather than the projector
/// reaching for any app-side state. Keeping the projection here means the status
/// shape lives entirely in `CMUXMobileCore` and cannot drift between the public
/// cache, the network status gate, and the no-private-metadata branch that all
/// build it.
///
/// Not `Sendable`: the produced `[String: Any]` carries Foundation reference
/// values, so the projector is constructed and consumed at one call site rather
/// than crossing isolation boundaries.
public struct MobileHostStatusPayloadProjector {
    /// The advertised capabilities, the single source of truth every status path
    /// reads so the lists cannot drift; iOS gates features like
    /// rename/pin/read-state/close on the entries present here.
    ///
    /// This also advertises `dogfood.v1`, the agent feedback round-trip
    /// (`dogfood.feedback.submit`). It is advertised on every build type so the
    /// privileged Send Feedback path (offered only to `@manaflow.ai` users on an
    /// active connection) works on Release (beta/prod) too; the sink itself is
    /// still gated by the same-account Stack-auth check the rest of the mobile
    /// data plane enforces.
    public static let capabilities: [String] = [
        "events.v1",
        "notification.badge.v1",
        "notification.dismiss.v1",
        "notification.reconcile.v1",
        "terminal.bytes.v1",
        "terminal.render_grid.v1",
        "terminal.replay.v1",
        "terminal.viewport.v1",
        "workspace.actions.v1",
        "workspace.read_state.v1",
        "workspace.close.v1",
        "dogfood.v1",
        // The workspace list carries group sections (group_id per workspace +
        // a top-level groups array) and the host accepts
        // workspace.group.collapse/expand from mobile. iOS feature-detects
        // this to render collapsible groups only against a Mac that emits them.
        "workspace.groups.v1",
    ]

    /// The JSON-shaped routes for the reply, already projected via
    /// ``CmxAttachRoute/mobileHostJSONObject`` at the call site.
    public let routesPayload: [[String: Any]]

    public init(routesPayload: [[String: Any]]) {
        self.routesPayload = routesPayload
    }

    /// The single shape every public `mobile.host.status` reply uses (the
    /// public-status cache, the network status gate, and the
    /// no-private-metadata branch), so the fields cannot drift. Identity-free:
    /// routes, fidelity, and capabilities are a reachability probe any peer may
    /// ask for, but the Mac's stable identity (`mac_device_id`,
    /// `mac_display_name`) is never on this unauthenticated surface — see the
    /// host's verified-caller reply (``identityPayload(deviceID:displayName:appVersion:appBuild:)``)
    /// for the reply that carries it.
    public var publicPayload: [String: Any] {
        [
            "routes": routesPayload,
            "terminal_fidelity": "render_grid",
            "capabilities": Self.capabilities,
        ]
    }

    /// ``publicPayload`` plus the Mac's identity, for a caller that has proven
    /// same-account Stack ownership. The pairing QR no longer carries the
    /// display name or the device id, so this reply is where a freshly paired
    /// phone learns what to call this Mac and which paired-Mac record the
    /// connection belongs to.
    ///
    /// All identity strings are resolved app-side and passed in: `deviceID`
    /// from `MobileHostIdentity.deviceID()`, `displayName` from
    /// `MobileHostIdentity.displayName()`, and `appVersion`/`appBuild` from
    /// `MobileHostBuildIdentity.current()`. A `nil` `displayName`, `appVersion`,
    /// or `appBuild` omits that key, matching the legacy projection exactly.
    public func identityPayload(
        deviceID: String,
        displayName: String?,
        appVersion: String?,
        appBuild: String?
    ) -> [String: Any] {
        var payload = publicPayload
        payload["mac_device_id"] = deviceID
        if let displayName {
            payload["mac_display_name"] = displayName
        }
        if let appVersion {
            payload["mac_app_version"] = appVersion
        }
        if let appBuild {
            payload["mac_app_build"] = appBuild
        }
        return payload
    }
}
