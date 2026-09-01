import CMUXMobileCore
public import CmuxMobileShellModel

extension MobileShellComposite {
    /// Whether the connected Mac supports browser-pane streaming.
    public var supportsBrowserStream: Bool { supportedHostCapabilities.contains(Self.browserStreamCapability) }
    /// Whether the connected Mac can reflow a browser stream to the phone viewport.
    public var supportsBrowserStreamViewport: Bool {
        supportsBrowserStream && supportedHostCapabilities.contains(Self.browserStreamViewportCapability)
    }
    /// Whether the connected Mac supports native browser dialog mirroring.
    public var supportsBrowserStreamDialogs: Bool {
        supportsBrowserStream && supportedHostCapabilities.contains(Self.browserStreamDialogCapability)
    }
    /// Whether the connected Mac can create a browser panel for the phone to stream.
    public var supportsBrowserStreamCreate: Bool {
        supportsBrowserStream && supportedHostCapabilities.contains(Self.browserStreamCreateCapability)
    }
    /// Whether the connected Mac supports Simulator pane streaming.
    public var supportsSimulatorStream: Bool {
        supportedHostCapabilities.contains(Self.simulatorStreamCapability)
    }
    /// Whether the connected Mac accepts Simulator touch/text/button input from the phone.
    public var supportsSimulatorInput: Bool {
        supportsSimulatorStream && supportedHostCapabilities.contains(Self.simulatorInputCapability)
    }
    /// Whether the connected Mac re-emits `simulator.state` on a fixed cadence
    /// while a stream session is active, making event silence a truthful
    /// staleness signal for the watchdog.
    public var supportsSimulatorKeepalive: Bool {
        supportsSimulatorStream && supportedHostCapabilities.contains(Self.simulatorKeepaliveCapability)
    }
    static let chatArtifactFoldersCapability = "chat.artifact.folders.v1"
    static let terminalArtifactListCapability = "terminal.artifact.list.v1"

    /// Whether the connected Mac supports workspace changes summaries and diffs.
    public var workspaceChangesCapable: Bool { supportedHostCapabilities.contains(Self.workspaceChangesCapability) }

    /// Verified render-grid sessions present only Mac-ordered terminal state.
    public var usesVerifiedTerminalReplay: Bool {
        terminalOutputTransport == .renderGrid
            && supportedHostCapabilities.contains(Self.terminalVerifiedReplayCapability)
    }

    /// Screen-anchored render-grid sessions receive active-area-anchored
    /// frames whose deltas carry exact scrolled-row counts, so this device
    /// keeps a deep local scrollback and scrolls the primary screen locally
    /// (no per-scroll round trip to the Mac). Full replays still flow through
    /// the verified pipeline when the host supports it.
    public var usesScreenAnchoredRenderGrid: Bool {
        terminalOutputTransport == .renderGrid
            && supportedHostCapabilities.contains(Self.terminalScreenAnchorCapability)
    }

    /// Whether the Mac supports workspace close requests.
    public var supportsWorkspaceCloseActions: Bool { supportedHostCapabilities.contains(Self.workspaceCloseCapability) }
    /// Whether the Mac supports workspace move/reorder requests.
    public var supportsWorkspaceMoveActions: Bool { supportedHostCapabilities.contains(Self.workspaceMoveCapability) && allowsMacScopedWorkspaceMutations }
    /// Whether the Mac supports workspace group mutation requests.
    public var supportsWorkspaceGroupActions: Bool { supportedHostCapabilities.contains(Self.workspaceGroupActionsCapability) && allowsMacScopedWorkspaceMutations }
    /// Whether the Mac supports creating a workspace directly inside a group.
    public var supportsWorkspaceCreateInGroup: Bool {
        supportedHostCapabilities.contains(Self.workspaceCreateInGroupCapability)
            && discoversMacScopedWorkspaceMutations
    }

    /// Whether a complete workspace-group inventory is available for one exact
    /// Mac pairing. An empty authoritative list means the Mac has no groups;
    /// `false` means the list may still be loading or stale.
    public func workspaceGroupInventoryIsAuthoritative(
        macDeviceID: String,
        instanceTag: String?
    ) -> Bool {
        let state = workspaceState(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        )
        return state?.status == .connected
            && state?.workspaceGroupsAreAuthoritative == true
    }

    /// The create-in-group capability for one exact connected pairing. `nil`
    /// means that pairing has not published a capability snapshot yet.
    public func workspaceCreateInGroupCapability(
        macDeviceID: String,
        instanceTag: String?
    ) -> Bool? {
        let state = workspaceState(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        )
        guard state?.status == .connected else { return nil }
        return state?.actionCapabilities.supportsWorkspaceCreateInGroup
    }

    private func workspaceState(
        macDeviceID: String,
        instanceTag: String?
    ) -> MacWorkspaceState? {
        let requestedKey = MacPairingKey(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        )
        if let exactState = workspacesByMac[requestedKey] {
            return exactState
        }
        guard instanceTag == nil,
              foregroundMacDeviceID.map({
                  cmxCanonicalDeviceID($0) == cmxCanonicalDeviceID(macDeviceID)
              }) == true,
              foregroundMacKey.normalizedInstanceTag == nil else {
            // Tagged pairings must never borrow another app instance's state.
            return nil
        }
        return workspacesByMac[foregroundMacKey]
    }
    /// Whether the Mac supports creating workspace groups from iOS.
    public var supportsWorkspaceGroupCreate: Bool {
        supportedHostCapabilities.contains(Self.workspaceGroupCreateCapability)
            && discoversMacScopedWorkspaceMutations
    }
    /// Whether the New Task composer entrypoint is available. A connected
    /// Mac's capability snapshot is authoritative for that Mac: any connected
    /// Mac advertising task creation shows the entrypoint, and a fleet of
    /// connected Macs that all lack it (remote flag off, or older builds)
    /// hides it. With zero connected Macs there is no snapshot to consult, so
    /// the entrypoint stays visible and the composer warns that no Mac is
    /// connected instead of the button silently disappearing while offline.
    public var supportsTaskComposer: Bool {
        var sawConnectedMac = false
        if connectionState == .connected {
            if supportedHostCapabilities.contains(Self.taskCreateCapability) {
                return true
            }
            sawConnectedMac = true
        }
        for (_, subscription) in secondaryMacSubscriptions {
            if subscription.supportedHostCapabilities.contains(Self.taskCreateCapability) {
                return true
            }
            sawConnectedMac = true
        }
        // With no connected Mac the composer normally gets the benefit of the
        // doubt (offline Macs may support tasks once they come up) — but not
        // when the only listed computer is the demonstration Mac, which can
        // never run a real task.
        return !sawConnectedMac && !pairedMacsAreDemonstrationOnly
    }

    /// True while at least one Mac session is live: the foreground connection
    /// or any control-role secondary. The task composer keys its "No Mac is
    /// connected" warning off this so the warning clears the moment any Mac
    /// comes up, not only the foreground one.
    public var hasAnyConnectedMac: Bool {
        connectionState == .connected || !secondaryMacSubscriptions.isEmpty
    }
    /// Whether the Mac supports dogfood feedback submission.
    public var supportsDogfoodFeedback: Bool { supportedHostCapabilities.contains(Self.dogfoodFeedbackCapability) }
    /// Whether the Mac supports chat artifact stat/fetch/thumbnail/list RPCs.
    public var supportsChatArtifacts: Bool { supportedHostCapabilities.contains(Self.chatArtifactCapability) }
    /// Whether the Mac supports session-wide artifact gallery paging and search.
    public var supportsChatArtifactGallery: Bool {
        supportedHostCapabilities.contains(Self.chatArtifactGalleryCapability)
    }
    /// Whether the Mac supports recursive chat artifact folder browsing.
    public var supportsChatArtifactFolders: Bool {
        supportedHostCapabilities.contains(Self.chatArtifactFoldersCapability)
    }
    /// Whether the Mac supports terminal artifact scan/stat/fetch/thumbnail RPCs.
    public var supportsTerminalArtifacts: Bool { supportedHostCapabilities.contains(Self.terminalArtifactCapability) }
    /// Whether the Mac supports lifecycle-bound panel stat/fetch/thumbnail RPCs.
    public var supportsPanelArtifacts: Bool { supportedHostCapabilities.contains(Self.panelArtifactCapability) }

    /// Whether the workspace's owning Mac can serve panel file reads. The
    /// panel artifact loader always talks to the foreground Mac's chat event
    /// source, so a secondary Mac's surface must stay on the fallback card
    /// even when that Mac advertises the capability.
    public func supportsPanelArtifacts(in workspaceID: MobileWorkspacePreview.ID) -> Bool {
        workspaceMutationTarget(for: workspaceID).isForeground && supportsPanelArtifacts
    }
    public var supportsIrohArtifactLane: Bool {
        supportedHostCapabilities.contains(Self.irohArtifactLaneCapability)
    }
    /// Whether the Mac supports terminal-scoped directory listing.
    public var supportsTerminalArtifactList: Bool {
        supportedHostCapabilities.contains(Self.terminalArtifactListCapability)
    }
}
