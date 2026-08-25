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
public enum DeeplinkWorkspaceNavigationOrigin: Equatable, Sendable {
    case external
    case notificationFeed
}

public struct DeeplinkWorkspaceNavigationRequest: Equatable, Sendable {
    public let token: UUID
    public let workspaceID: MobileWorkspacePreview.ID
    public let origin: DeeplinkWorkspaceNavigationOrigin
}

extension CMUXMobileShellStore {
    /// Select `id` and ask the shell to navigate to it (push the compact
    /// stack). Called by the push coordinator when a parked notification tap
    /// resolves; the workspace is expected to exist in ``workspaces``.
    public func navigateToWorkspaceForDeeplink(
        _ id: MobileWorkspacePreview.ID,
        origin: DeeplinkWorkspaceNavigationOrigin = .external
    ) {
        selectedWorkspaceID = id
        deeplinkWorkspaceNavigationRequest = DeeplinkWorkspaceNavigationRequest(
            token: UUID(),
            workspaceID: id,
            origin: origin
        )
    }

    /// Hand the pending deep-link navigation intent to the shell and clear it
    /// so a later layout remount cannot replay a stale push.
    public func consumeDeeplinkWorkspaceNavigationRequest() -> MobileWorkspacePreview.ID? {
        defer { deeplinkWorkspaceNavigationRequest = nil }
        return deeplinkWorkspaceNavigationRequest?.workspaceID
    }

    /// The current UI row id for a Mac-local workspace id, if that workspace is
    /// loaded. Push payloads carry Mac-local ids; the aggregated list may scope
    /// row ids by Mac for SwiftUI identity.
    public func workspaceID(matchingRemoteWorkspaceID remoteWorkspaceID: String) -> MobileWorkspacePreview.ID? {
        workspaceID(matchingRemoteWorkspaceID: remoteWorkspaceID, macDeviceID: nil)
    }

    /// The current UI row id for a Mac-local workspace id owned by a specific
    /// Mac. New push payloads carry the Mac's device id so duplicate local
    /// workspace ids across paired Macs do not resolve to the first visible row.
    public func workspaceID(
        matchingRemoteWorkspaceID remoteWorkspaceID: String,
        macDeviceID: String?,
        instanceTag: String? = nil
    ) -> MobileWorkspacePreview.ID? {
        rowWorkspaceID(
            forRemoteWorkspaceID: MobileWorkspacePreview.ID(rawValue: remoteWorkspaceID),
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        )
    }

    /// Whether the visible selection matches a Mac-local workspace id.
    public func selectedWorkspaceMatches(remoteWorkspaceID: String) -> Bool {
        selectedWorkspaceMatches(remoteWorkspaceID: remoteWorkspaceID, macDeviceID: nil)
    }

    /// Whether the visible selection matches a Mac-local workspace id owned by
    /// a specific Mac.
    public func selectedWorkspaceMatches(
        remoteWorkspaceID: String,
        macDeviceID: String?,
        instanceTag: String? = nil
    ) -> Bool {
        guard let selectedWorkspaceID,
              let selectedWorkspace = workspaces.first(where: { $0.id == selectedWorkspaceID }),
              selectedWorkspace.rpcWorkspaceID.rawValue == remoteWorkspaceID else {
            return false
        }
        guard let macDeviceID, !macDeviceID.isEmpty else {
            return selectedWorkspace.macDeviceID == nil
                && selectedWorkspace.macInstanceTag == nil
                && instanceTag == nil
        }
        guard let selectedMacDeviceID = selectedWorkspace.macDeviceID else {
            return false
        }
        return MacPairingKey(
            macDeviceID: selectedMacDeviceID,
            instanceTag: selectedWorkspace.macInstanceTag
        ) == MacPairingKey(macDeviceID: macDeviceID, instanceTag: instanceTag)
    }

    /// The workspace whose terminal list contains `surfaceID`, if any. Used by
    /// the push coordinator to resolve surface-only notification deep links to
    /// a navigable workspace, and to keep a tap parked until the terminal's
    /// snapshot has arrived.
    public func workspaceID(containingSurfaceID surfaceID: String) -> MobileWorkspacePreview.ID? {
        workspaceID(containingSurfaceID: surfaceID, macDeviceID: nil)
    }

    /// The workspace owned by `macDeviceID` whose terminal list contains
    /// `surfaceID`, if any. A payload without owner identity can resolve only
    /// an unowned bootstrap row.
    public func workspaceID(
        containingSurfaceID surfaceID: String,
        macDeviceID: String?,
        instanceTag: String? = nil
    ) -> MobileWorkspacePreview.ID? {
        workspaceID(
            forTerminalID: surfaceID,
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        )
    }

    /// Whether `surfaceID` is a terminal of the workspace `workspaceID`.
    public func workspace(_ workspaceID: MobileWorkspacePreview.ID, containsSurfaceID surfaceID: String) -> Bool {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else {
            return false
        }
        return workspace.terminals.contains(where: { $0.id.rawValue == surfaceID })
    }

    /// The workspace whose terminal list contains `terminalID`, if any.
    /// Terminal lanes exist only on the foreground connection, so this
    /// internal convenience scopes by the authoritative foreground pairing:
    /// a sibling build's colliding surface id must neither shadow the live
    /// terminal's row nor nil it out through the ambiguity check below. When
    /// foreground identity is known, a miss is authoritative — falling back to
    /// a global search could resolve a sibling's retained snapshot and route
    /// terminal commands to the wrong build's workspace id.
    func workspaceID(forTerminalID terminalID: String) -> MobileWorkspacePreview.ID? {
        guard let foregroundMacDeviceID else {
            return workspaceID(forTerminalID: terminalID, macDeviceID: nil)
        }
        if let scoped = workspaceID(
            forTerminalID: terminalID,
            macDeviceID: foregroundMacDeviceID,
            instanceTag: activeMacInstanceTag
        ) {
            return scoped
        }
        // Unowned rows (anonymous seeding, pre-stamp identity transitions) are
        // foreground-owned by construction — sibling snapshots are always
        // stamped with their device and tag — so they stay reachable without
        // reopening the global fallback that could resolve a sibling's row.
        return workspaces.first { workspace in
            workspace.macDeviceID == nil
                && workspace.terminals.contains(where: { $0.id.rawValue == terminalID })
        }?.id
    }

    /// The workspace owned by `macDeviceID` whose terminal list contains
    /// `terminalID`, if any.
    func workspaceID(forTerminalID terminalID: String, macDeviceID: String?) -> MobileWorkspacePreview.ID? {
        workspaceID(forTerminalID: terminalID, macDeviceID: macDeviceID, instanceTag: nil)
    }

    /// Tag-aware variant: a non-nil `instanceTag` matches only rows proven to
    /// belong to that build, so sibling builds' colliding Mac-local terminal
    /// ids can never resolve to the wrong workspace.
    func workspaceID(
        forTerminalID terminalID: String,
        macDeviceID: String?,
        instanceTag: String?
    ) -> MobileWorkspacePreview.ID? {
        func matches(_ workspace: MobileWorkspacePreview) -> Bool {
            if let macDeviceID, !macDeviceID.isEmpty {
                guard let workspaceMacDeviceID = workspace.macDeviceID,
                      MacPairingKey(
                          macDeviceID: workspaceMacDeviceID,
                          instanceTag: workspace.macInstanceTag
                      ) == MacPairingKey(
                          macDeviceID: macDeviceID,
                          instanceTag: instanceTag
                      ) else { return false }
            } else {
                guard instanceTag?.isEmpty != false,
                      workspace.macDeviceID == nil,
                      workspace.macInstanceTag == nil else { return false }
            }
            return workspace.terminals.contains(where: { $0.id.rawValue == terminalID })
        }
        // Exact pairing lookups are unambiguous and sit on per-frame terminal
        // paths (viewport, replay, scroll): return at the first hit with no
        // allocation.
        if let instanceTag, !instanceTag.isEmpty {
            return workspaces.first(where: matches)?.id
        }
        // Sibling builds can reuse Mac-local surface ids; a tag-less lookup
        // that matches two builds of one device fails closed rather than
        // deep-linking into the wrong instance. The single-match fast path
        // (the overwhelmingly common case) tracks only the first owner and
        // allocates no sets.
        var firstMatchID: MobileWorkspacePreview.ID?
        var firstOwner: MacPairingKey?
        var owners: Set<MacPairingKey> = []
        var ownerDevices: Set<String> = []
        for workspace in workspaces where matches(workspace) {
            let owner = workspace.macDeviceID.map {
                MacPairingKey(macDeviceID: $0, instanceTag: workspace.macInstanceTag)
            }
            if firstMatchID == nil {
                firstMatchID = workspace.id
                firstOwner = owner
                continue
            }
            if owners.isEmpty, let firstOwner {
                owners.insert(firstOwner)
                ownerDevices.insert(firstOwner.canonicalMacDeviceID)
            }
            guard let owner else { continue }
            if owners.insert(owner).inserted,
               !ownerDevices.insert(owner.canonicalMacDeviceID).inserted {
                return nil
            }
        }
        return firstMatchID
    }
}
