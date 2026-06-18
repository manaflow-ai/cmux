public import CmuxMobileShellModel
public import Foundation

/// A one-shot "actually navigate to this workspace" intent from a
/// notification-tap deep link.
///
/// Setting `selectedWorkspaceID` alone is not enough on the compact (iPhone)
/// layout: the shell's `NavigationStack` deliberately ignores selection
/// changes while its path is empty so the attach-time auto-selection cannot
/// yank the user off the workspace list. A deep link must push, so it carries
/// this explicit request, which the shell consumes exactly once. The token
/// makes repeated taps on the same workspace distinguishable.
public struct DeeplinkWorkspaceNavigationRequest: Equatable, Sendable {
    public let token: UUID
    public let workspaceID: MobileWorkspacePreview.ID
}

extension CMUXMobileShellStore {
    /// Select `id` and ask the shell to navigate to it (push the compact
    /// stack). Called by the push coordinator when a parked notification tap
    /// resolves; the workspace is expected to exist in ``workspaces``.
    public func navigateToWorkspaceForDeeplink(_ id: MobileWorkspacePreview.ID) {
        selectedWorkspaceID = id
        deeplinkWorkspaceNavigationRequest = DeeplinkWorkspaceNavigationRequest(
            token: UUID(),
            workspaceID: id
        )
    }

    /// Hand the pending deep-link navigation intent to the shell and clear it
    /// so a later layout remount cannot replay a stale push.
    public func consumeDeeplinkWorkspaceNavigationRequest() -> MobileWorkspacePreview.ID? {
        defer { deeplinkWorkspaceNavigationRequest = nil }
        return deeplinkWorkspaceNavigationRequest?.workspaceID
    }

    /// The workspace whose terminal list contains `surfaceID`, if any. Used by
    /// the push coordinator to resolve surface-only notification deep links to
    /// a navigable workspace, and to keep a tap parked until the terminal's
    /// snapshot has arrived.
    public func workspaceID(containingSurfaceID surfaceID: String) -> MobileWorkspacePreview.ID? {
        workspaceID(forTerminalID: surfaceID)
    }

    /// Whether `surfaceID` is a terminal of the workspace `workspaceID`.
    public func workspace(_ workspaceID: MobileWorkspacePreview.ID, containsSurfaceID surfaceID: String) -> Bool {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else {
            return false
        }
        return workspace.terminals.contains(where: { $0.id.rawValue == surfaceID })
    }

    /// The workspace (on the active heavy Mac) whose terminal list contains the
    /// terminal identified by `surfaceKey`, if any.
    ///
    /// `surfaceKey` is the Mac-scoped surface key (`"<deviceId>#<terminalID>"`,
    /// see ``ScopedTerminalID/surfaceKey``); a bare terminal id (no separator)
    /// is accepted as the unscoped case. Resolution is the multi-Mac routing
    /// guard: the heavy client only owns the active Mac's surfaces, so a key
    /// whose `deviceId` is NOT the active Mac's resolves to `nil` — a colliding
    /// bare terminal id on another Mac can never match the active Mac's
    /// workspace. The scan still compares the BARE terminal id (the wire id is
    /// Mac-local); the scope only gates which Mac the key may belong to.
    func workspaceID(forTerminalID surfaceKey: String) -> MobileWorkspacePreview.ID? {
        let scoped = ScopedTerminalID(surfaceKey: surfaceKey)
        // A scoped key for a non-active Mac must not resolve against the heavy
        // client's workspaces, even if the bare terminal id happens to collide.
        // An unscoped ("") key predates multi-Mac scoping (single-Mac/preview)
        // and is allowed to match.
        if !scoped.deviceId.isEmpty, let activeDeviceID, scoped.deviceId != activeDeviceID {
            return nil
        }
        let bareTerminalID = scoped.terminalID.rawValue
        for workspace in workspaces {
            if workspace.terminals.contains(where: { $0.id.rawValue == bareTerminalID }) {
                return workspace.id
            }
        }
        return nil
    }

    /// The bare, Mac-local terminal id to send on the wire for a scoped surface
    /// key, but ONLY when the key belongs to the active heavy Mac.
    ///
    /// Returns `nil` for a key scoped to a non-active Mac (the heavy client
    /// cannot service it), which makes every wire-bound terminal call
    /// (`input`, `mouse`, `scroll`, `viewport`, `replay`) a safe no-op rather
    /// than routing a colliding bare id to the wrong Mac. An unscoped key falls
    /// through to its bare terminal id for the single-Mac case.
    func wireTerminalID(forSurfaceKey surfaceKey: String) -> String? {
        let scoped = ScopedTerminalID(surfaceKey: surfaceKey)
        if !scoped.deviceId.isEmpty, let activeDeviceID, scoped.deviceId != activeDeviceID {
            return nil
        }
        return scoped.terminalID.rawValue
    }

    /// The local surface key for a bare wire terminal id arriving from the
    /// active heavy Mac (a `terminal.bytes` / `terminal.render_grid` event, or a
    /// replay response). Scoped with ``activeDeviceID`` so the byte-delivery
    /// dictionaries are keyed identically to the surface the UI registered. When
    /// there is no active device id (single-Mac/preview), the key is unscoped.
    func surfaceKeyForActiveMac(wireTerminalID: String) -> String {
        ScopedTerminalID(
            deviceId: activeDeviceID ?? "",
            terminalID: MobileTerminalPreview.ID(rawValue: wireTerminalID)
        ).surfaceKey
    }
}
