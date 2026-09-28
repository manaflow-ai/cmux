public import CmuxMobileShellModel
public import Foundation

/// SSH computers (PRD `docs/prd/ios-direct-ssh.md`) ride the same seams as
/// the demonstration computer: rows live in `workspacesByMac`, output enters
/// the ordinary per-surface stream, and every input/replay/viewport funnel
/// that would otherwise talk to a Mac branches on a *locally served* surface
/// first. Ownership is by identifier namespace (`cmux-ssh-`), never by live
/// session state, so lifecycle fences hold through reconnects.
@MainActor
extension MobileShellComposite: MobileSSHComputersSink {
    // MARK: Sink

    func sshPublishWorkspaceState(_ state: MacWorkspaceState) {
        let key = MacPairingKey(macDeviceID: state.macDeviceID, instanceTag: nil)
        if workspacesByMac[key] != state {
            workspacesByMac[key] = state
        }
    }

    func sshRemoveWorkspaceState(computerID: String) {
        workspacesByMac.removeValue(forKey: MacPairingKey(macDeviceID: computerID, instanceTag: nil))
    }

    func sshDeliver(_ bytes: Data, surfaceID: String) {
        // SSH bytes are raw PTY output emulated by the phone's own Ghostty;
        // they never take part in a Mac's verified render-grid replay.
        _ = deliverTerminalOutput(
            TerminalOutputDelivery(
                bytes: bytes,
                replaceable: false,
                viewportPolicy: sshViewportPolicy(surfaceID: surfaceID),
                requiresVerifiedReplay: false
            ),
            surfaceID: surfaceID,
            bypassReplayBarrier: true
        )
    }

    // MARK: Ownership

    func sshOwnsSurface(_ surfaceID: String) -> Bool {
        MobileSSHIdentifier(surfaceID).isSSH
    }

    func sshOwnsMac(deviceID: String?) -> Bool {
        deviceID.map { MobileSSHIdentifier($0).isSSH } ?? false
    }

    /// Whether a per-computer store key belongs to an SSH computer. Mac
    /// lifecycle passes (secondary reconciliation, team switches, outage
    /// downgrades) must leave these entries to the SSH runtime.
    func sshOwnsPairingKey(_ key: MacPairingKey) -> Bool {
        MobileSSHIdentifier(key.canonicalMacDeviceID).isSSH
    }

    func sshOwnsWorkspaceRow(_ id: MobileWorkspacePreview.ID) -> Bool {
        if MobileSSHIdentifier(id.rawValue).isSSH { return true }
        guard let row = workspaces.first(where: { $0.id == id }) else { return false }
        return sshOwnsMac(deviceID: row.macDeviceID)
    }

    /// Whether a surface is served on the phone (demonstration or SSH)
    /// rather than by a paired Mac.
    func locallyServedOwnsSurface(_ surfaceID: String) -> Bool {
        demonstrationOwnsSurface(surfaceID) || sshOwnsSurface(surfaceID)
    }

    func locallyServedOwnsWorkspaceRow(_ id: MobileWorkspacePreview.ID) -> Bool {
        demonstrationOwnsWorkspaceRow(id) || sshOwnsWorkspaceRow(id)
    }

    /// Routes input for locally served surfaces. Returns `false` for Mac
    /// surfaces so callers fall through to the RPC pipeline.
    @discardableResult
    func handleLocallyServedTerminalInput(_ text: String, surfaceID: String) -> Bool {
        if handleDemonstrationTerminalInput(text, surfaceID: surfaceID) { return true }
        guard sshOwnsSurface(surfaceID) else { return false }
        sshComputers.input(Data(text.utf8), surfaceID: surfaceID)
        return true
    }

    /// Composer paste into an SSH terminal: multi-line text is bracketed so
    /// shells treat it as one paste, then the submit key runs it.
    func handleSSHTerminalPaste(_ text: String, submitKey: String, surfaceID: String) -> Bool {
        var payload = text.contains("\n") ? "\u{1B}[200~" + text + "\u{1B}[201~" : text
        if submitKey == "return" { payload += "\r" }
        sshComputers.input(Data(payload.utf8), surfaceID: surfaceID)
        return true
    }

    func deliverLocallyServedTerminalReplay(surfaceID: String) {
        if sshOwnsSurface(surfaceID) {
            sshComputers.replay(surfaceID: surfaceID)
        } else {
            deliverDemonstrationTerminalReplay(surfaceID: surfaceID)
        }
    }

    /// Resolves an SSH surface to its row regardless of the foreground Mac.
    func sshWorkspaceID(forTerminalID terminalID: String) -> MobileWorkspacePreview.ID? {
        workspaces.first { row in
            sshOwnsMac(deviceID: row.macDeviceID) && row.terminals.contains { $0.id.rawValue == terminalID }
        }?.id
    }

    // MARK: Computer actions

    /// Opens an SSH computer: connects, asks first-connect questions, and
    /// lists its workspaces.
    public func openSSHComputer(hostID: UUID) async {
        await sshComputers.open(hostID: hostID)
    }

    /// Reconnects an SSH computer the user is looking at when nothing is
    /// live (see ``MobileSSHComputers/autoConnect(hostID:)``). Idempotent.
    public func autoConnectSSHComputer(hostID: UUID) {
        sshComputers.autoConnect(hostID: hostID)
    }

    /// Creates a workspace of `kind` on an SSH computer (a cmux-tui
    /// workspace, a tmux session, or a shell) and returns its row id.
    @discardableResult
    public func createSSHWorkspace(hostID: UUID, kind: MobileSSHWorkspaceKind) async -> MobileWorkspacePreview.ID? {
        guard let scoped = await sshComputers.createWorkspace(hostID: hostID, kind: kind) else { return nil }
        // Aggregation may Mac-scope row ids; match the host-local id too.
        return workspaces.first { $0.id.rawValue == scoped || $0.rpcWorkspaceID.rawValue == scoped }?.id
    }

    /// The SSH computer's device id for the workspace list's computer filter.
    public func sshComputerDeviceID(hostID: UUID) -> String {
        MobileSSHIdentifier(computerOf: hostID).rawValue
    }

    /// Whether a computer id names an SSH computer rather than a paired Mac.
    /// Mac-only states (pairing, version gate, list-auth) never apply to it.
    public nonisolated static func isSSHComputerID(_ computerID: String) -> Bool {
        MobileSSHIdentifier(computerID).isSSH
    }

    /// The SSH host behind a computer device id, if any.
    public func sshHostID(computerDeviceID: String) -> UUID? {
        MobileSSHIdentifier(computerDeviceID).hostID
    }
}

@MainActor
extension MobileShellComposite {
    /// Connects the SSH runtime to this store and publishes saved hosts.
    /// Called once by the app composition root after construction.
    public func startSSHComputers() async {
        sshComputers.sink = self
        await sshComputers.reload()
    }
}

@MainActor
extension MobileShellComposite {
    /// For SSH surfaces, whether a server-side emulator answers terminal
    /// queries: cmux-tui's, or tmux's (control mode streams pane output, and
    /// tmux answers its panes' queries itself); a shell's phone answers.
    /// Decided per surface by its kind. `nil` for surfaces a Mac or the demo
    /// serves.
    public func sshServerAnswersTerminalQueries(surfaceID: String) -> Bool? {
        guard MobileSSHIdentifier(surfaceID).hostID != nil else { return nil }
        guard let kind = sshComputers.kind(ofScopedID: surfaceID) else { return false }
        return kind != .shell
    }

    /// Whether the phone's own emulator is the terminal for this surface
    /// (every SSH surface), so scrolling and replies stay local.
    public func surfaceIsLocallyEmulated(_ surfaceID: String) -> Bool {
        sshOwnsSurface(surfaceID)
    }
}
