import AppKit
import Bonsplit
import CmuxTerminal
import CmuxTerminalSharing
import CmuxTerminalSizing
import Foundation
import SwiftUI
import SystemConfiguration

/// Shared terminal sizing for local terminals (the Mac is the host) and the
/// mobile side of Cloud terminals (the Mac is the relay).
/// Contract: docs/shared-terminal-sizing.md.
@MainActor
extension TerminalController {
    static let mobileSizeStateTopic = "mobile.terminal.size_state"
    static let mobileDetachedTopic = "mobile.terminal.detached"

    /// The Mac's user-visible computer name, read once without DNS.
    static let localComputerName: String? = SCDynamicStoreCopyComputerName(nil, nil) as String?

    /// This Mac's identity as a participant.
    func localSizingIdentity() -> TerminalSharingIdentity {
        let user = MobileHostService.shared.currentLocalSizingUser()
        return TerminalSharingIdentity(
            userID: user?.id,
            displayName: user?.displayName,
            deviceName: Self.localComputerName
        )
    }

    // MARK: - Engine resolution

    /// Runs the shared-sizing decision after the phone reports for a surface
    /// changed, then applies it to the Ghostty surface. Replaces the legacy
    /// "smallest attached viewport wins" rule.
    ///
    /// - Parameter immediate: `true` when a phone explicitly left, so the
    ///   resulting size applies without the governor's stability window.
    /// - Returns: the grid the phone's replay fence should expect.
    func resolveSharedSizing(
        surfaceID: UUID,
        reports: [String: MobileViewportReport],
        countsOverride: (clientID: String, value: Bool?)? = nil,
        immediate: Bool = false,
        reason: String
    ) -> (columns: Int, rows: Int)? {
        if let relay = cloudSizingRelaysBySurfaceID[surfaceID]?.value, relay.relaysPhones {
            // The cmux-tui daemon decides a Cloud terminal's grid; the local
            // mirror follows the remote grid it reports back.
            relay.relayPhones(phoneParticipants(reports: reports, surfaceID: surfaceID))
            if let countsOverride {
                relay.relayPhoneCountsOverride(clientID: countsOverride.clientID, value: countsOverride.value)
            }
            return currentMobileViewportGrid(surfaceID: surfaceID)
        }
        guard var host = localSizingHost(surfaceID: surfaceID, create: !reports.isEmpty) else {
            return legacyMinimumSizing(surfaceID: surfaceID, reports: reports, immediate: immediate, reason: reason)
        }
        let previous = host.state
        if let viewport = localSizingControllersBySurfaceID[surfaceID]?.naturalViewport() {
            host.updateMacViewport(viewport)
        }
        host.syncPhones(Array(phoneParticipants(reports: reports, surfaceID: surfaceID).values))
        if let countsOverride {
            host.setCountsOverride(
                LocalTerminalSizingHost.phoneParticipantID(clientID: countsOverride.clientID),
                countsOverride.value
            )
        }
        localSizingHostsBySurfaceID[surfaceID] = host
        return applyLocalSizing(surfaceID: surfaceID, previous: previous, immediate: immediate, reason: reason)
    }

    /// The pre-shared-sizing rule, kept for manual-I/O mirrors whose remote
    /// side has no sizing host (for example remote tmux).
    private func legacyMinimumSizing(
        surfaceID: UUID,
        reports: [String: MobileViewportReport],
        immediate: Bool,
        reason: String
    ) -> (columns: Int, rows: Int)? {
        guard let minColumns = reports.values.map(\.columns).min(),
              let minRows = reports.values.map(\.rows).min() else {
            governMobileViewportTarget(surfaceID: surfaceID, target: .uncapped, immediate: immediate, reason: reason)
            return nil
        }
        return governMobileViewportTarget(
            surfaceID: surfaceID,
            target: .cap(columns: minColumns, rows: minRows),
            immediate: immediate,
            reason: reason
        )
    }

    private func phoneParticipants(
        reports: [String: MobileViewportReport],
        surfaceID: UUID
    ) -> [String: TerminalSizingParticipant] {
        let identity = localSizingIdentity()
        var phones: [String: TerminalSizingParticipant] = [:]
        for (clientID, report) in reports where !isMobileClientDetached(surfaceID: surfaceID, clientID: clientID) {
            phones[clientID] = TerminalSizingParticipant(
                id: LocalTerminalSizingHost.phoneParticipantID(clientID: clientID),
                userID: identity.userID,
                displayName: identity.displayName,
                deviceKind: report.deviceKind,
                deviceName: report.deviceName,
                viewport: TerminalGridSize(cols: report.columns, rows: report.rows)
            )
        }
        return phones
    }

    /// Returns the local host of a surface, creating it (with the Mac pane as
    /// participant) when `create` is set and the surface is a local PTY.
    func localSizingHost(surfaceID: UUID, create: Bool) -> LocalTerminalSizingHost? {
        if let host = localSizingHostsBySurfaceID[surfaceID] { return host }
        guard create,
              let target = terminalSocketTarget(surfaceID: surfaceID),
              target.surface.ioMode == .exec else { return nil }
        let surface = target.surface
        let controller = LocalTerminalSharingController(surfaceID: surfaceID, surface: surface, owner: self)
        let viewport = controller.naturalViewport() ?? TerminalGridSize(cols: 80, rows: 24)
        let host = LocalTerminalSizingHost(
            macParticipant: localSizingIdentity().participant(
                id: "mac:\(surfaceID.uuidString.lowercased())",
                deviceKind: .mac,
                viewport: viewport
            ),
            initialSize: viewport
        )
        localSizingHostsBySurfaceID[surfaceID] = host
        localSizingControllersBySurfaceID[surfaceID] = controller
        ensureTerminalSharingPresentation()
        terminalSharing.register(controller, surfaceID: surfaceID)
        surface.onUncappedPixelSizeChanged = { [weak self] in
            // Hop out of the in-progress updateSize before re-applying.
            Task { @MainActor [weak self] in
                self?.localSizingMacViewportChanged(surfaceID: surfaceID)
            }
        }
        publishLocalSizing(surfaceID: surfaceID)
        return host
    }

    /// Applies the host's decision and publishes it when it changed.
    @discardableResult
    func applyLocalSizing(
        surfaceID: UUID,
        previous: TerminalSizingState?,
        immediate: Bool = false,
        reason: String
    ) -> (columns: Int, rows: Int)? {
        guard let host = localSizingHostsBySurfaceID[surfaceID] else { return nil }
        if host.state != previous { publishLocalSizing(surfaceID: surfaceID) }
        switch host.applyTarget {
        case let .grid(size):
            return governMobileViewportTarget(
                surfaceID: surfaceID,
                target: .cap(columns: size.cols, rows: size.rows),
                immediate: immediate,
                reason: reason
            )
        case .uncapped:
            if host.phoneParticipantIDs.isEmpty {
                // The last phone left. An explicit leave restores the pane
                // now; a TTL expiry keeps the governor's uncap window
                // (issue 13474).
                governMobileViewportTarget(
                    surfaceID: surfaceID,
                    target: .uncapped,
                    immediate: immediate,
                    reason: reason
                )
            } else if let governor = mobileViewportApplyGovernorsBySurfaceID[surfaceID] {
                // Ownership moved back to this Mac while phones stay attached:
                // restore the pane now instead of after the uncap window.
                teardownMobileViewportGovernor(surfaceID: surfaceID)
                if let applied = governor.applied, applied != .uncapped {
                    _ = performMobileViewportTarget(surfaceID: surfaceID, target: .uncapped, reason: reason)
                }
            }
            return currentMobileViewportGrid(surfaceID: surfaceID)
        }
    }

    /// The Mac pane resized: re-report its grid as the Mac participant's viewport.
    func localSizingMacViewportChanged(surfaceID: UUID) {
        guard var host = localSizingHostsBySurfaceID[surfaceID],
              let viewport = localSizingControllersBySurfaceID[surfaceID]?.naturalViewport() else { return }
        let previous = host.state
        guard host.updateMacViewport(viewport) else { return }
        localSizingHostsBySurfaceID[surfaceID] = host
        applyLocalSizing(surfaceID: surfaceID, previous: previous, reason: "mac.viewport")
    }

    /// Explicit keyboard, paste or mouse input on the Mac pane. O(1) when the
    /// terminal is not shared, because it runs on every keystroke.
    func noteLocalTerminalSizingActivity(surfaceID: UUID) {
        guard var host = localSizingHostsBySurfaceID[surfaceID] else { return }
        let previous = host.state
        guard host.noteActivity(host.macParticipantID) else { return }
        localSizingHostsBySurfaceID[surfaceID] = host
        applyLocalSizing(surfaceID: surfaceID, previous: previous, reason: "mac.activity")
    }

    private func noteMobileSizingActivity(surfaceID: UUID, clientID: String) {
        if let relay = cloudSizingRelaysBySurfaceID[surfaceID]?.value, relay.relaysPhones {
            relay.relayPhoneActivity(clientID: clientID)
            return
        }
        guard var host = localSizingHostsBySurfaceID[surfaceID] else { return }
        let previous = host.state
        guard host.noteActivity(LocalTerminalSizingHost.phoneParticipantID(clientID: clientID)) else { return }
        localSizingHostsBySurfaceID[surfaceID] = host
        applyLocalSizing(surfaceID: surfaceID, previous: previous, reason: "mobile.activity")
    }

    /// Drops every local host (account change or test reset).
    func resetLocalSizingHosts() {
        for (surfaceID, controller) in localSizingControllersBySurfaceID {
            controller.surface?.onUncappedPixelSizeChanged = nil
            terminalSharing.unregister(controller, surfaceID: surfaceID)
        }
        localSizingHostsBySurfaceID.removeAll()
        localSizingControllersBySurfaceID.removeAll()
        cloudDetachedPhonesBySurfaceID.removeAll()
    }

    // MARK: - Presentation

    /// Routes store changes to the pane overlay and the tab accessory. Set
    /// once, the first time any host or relay registers.
    func ensureTerminalSharingPresentation() {
        guard terminalSharing.onChange == nil else { return }
        terminalSharing.onChange = { [weak self] surfaceID in
            self?.terminalSharingDidChange(surfaceID: surfaceID)
        }
    }

    private func terminalSharingDidChange(surfaceID: UUID) {
        let snapshot = terminalSharing.snapshot(for: surfaceID)
        if snapshot == nil { terminalSizePanelPresenter.close(surfaceID: surfaceID) }
        if let surface = GhosttyApp.terminalSurfaceRegistry.terminalSurface(id: surfaceID) {
            surface.hostedView.setTerminalSharingSnapshot(
                snapshot,
                surface: surface,
                onShowSizePanel: { [weak self] in
                    _ = self?.presentTerminalSizePanel(surfaceID: surfaceID, confirmDisconnectOthers: false)
                },
                onReattach: { [weak self] asViewer in
                    _ = self?.terminalSharing.reattach(surfaceID: surfaceID, asViewer: asViewer)
                }
            )
        }
        if let workspace = AppDelegate.shared?.workspaceContainingPanel(panelId: surfaceID)?.workspace {
            workspace.updateTerminalSharingPresence(panelId: surfaceID, snapshot: snapshot)
        }
    }

    /// Opens the size panel for a terminal, anchored at its tab in the tab
    /// strip (tab accessory, pane chip, context menu, command palette and
    /// shortcut all land here).
    ///
    /// - Parameters:
    ///   - surfaceID: The terminal.
    ///   - confirmDisconnectOthers: Open with the Disconnect Others confirmation showing.
    ///   - toggle: Close instead when the panel is already open for this terminal
    ///     (the tab accessory's click).
    /// - Returns: `false` when the terminal has nothing on screen to anchor to.
    @discardableResult
    func presentTerminalSizePanel(surfaceID: UUID, confirmDisconnectOthers: Bool, toggle: Bool = false) -> Bool {
        if toggle, terminalSizePanelPresenter.consumeToggleClose(surfaceID: surfaceID) { return true }
        if terminalSharing.snapshot(for: surfaceID) == nil {
            _ = localSizingHost(surfaceID: surfaceID, create: true)
        }
        guard let anchor = terminalSizePanelAnchor(surfaceID: surfaceID) else { return false }
        let panel = TerminalSizePanelView(
            store: terminalSharing,
            surfaceID: surfaceID,
            separatorColor: Color(nsColor: TerminalSizingChromeColor.separator(surfaceID: surfaceID)),
            confirmDisconnectOthers: confirmDisconnectOthers
        )
        terminalSizePanelPresenter.present(panel, surfaceID: surfaceID, anchor: anchor.view, rect: anchor.rect)
        return true
    }

    /// The terminal's tab accessory, else its tab item, in the tab strip.
    /// Falls back to the pane's top-right corner only when the tab strip does
    /// not show the tab (for example a hidden tab bar).
    private func terminalSizePanelAnchor(surfaceID: UUID) -> (view: NSView, rect: NSRect?)? {
        if let workspace = AppDelegate.shared?.workspaceContainingPanel(panelId: surfaceID)?.workspace,
           let tabID = workspace.surfaceIdFromPanelId(surfaceID),
           let view = workspace.bonsplitController.popoverAnchorView(for: tabID) {
            return (view, nil)
        }
        guard let surface = GhosttyApp.terminalSurfaceRegistry.terminalSurface(id: surfaceID),
              surface.hostedView.window != nil else { return nil }
        let pane = surface.hostedView
        let corner = NSRect(x: pane.bounds.maxX - 24, y: pane.isFlipped ? 0 : pane.bounds.maxY - 4, width: 20, height: 4)
        return (pane, corner)
    }

    // MARK: - Publishing

    /// Publishes a local host's state to the store and to every phone.
    func publishLocalSizing(surfaceID: UUID) {
        guard let host = localSizingHostsBySurfaceID[surfaceID] else {
            terminalSharing.publish(nil, surfaceID: surfaceID)
            return
        }
        terminalSharing.publish(
            TerminalSharingSnapshot(state: host.state, selfParticipantID: host.macParticipantID, isCloud: false),
            surfaceID: surfaceID
        )
        emitMobileSizeState(surfaceID: surfaceID, state: host.state) { clientIDs in
            clientIDs
                .map { LocalTerminalSizingHost.phoneParticipantID(clientID: $0) }
                .first { host.state.participant($0) != nil }
        }
    }

    /// Pushes `mobile.terminal.size_state` with each phone's own participant id.
    func emitMobileSizeState(
        surfaceID: UUID,
        state: TerminalSizingState,
        selfParticipantID: @escaping (Set<String>) -> String?
    ) {
        let stateObject = TerminalSizingWireCoder().jsonObject(state)
        MobileHostService.shared.emitClientScopedEvent(topic: Self.mobileSizeStateTopic) { clientIDs in
            [
                "surface_id": surfaceID.uuidString,
                "state": stateObject,
                "self_participant_id": selfParticipantID(clientIDs) ?? NSNull(),
            ]
        }
    }

    /// Pushes `mobile.terminal.detached` to the one phone it concerns.
    func emitMobileDetached(surfaceID: UUID, clientID: String, detachment: TerminalSharingDetachment) {
        let payload = TerminalSizingWireCoder().detachedPayload(surfaceID: surfaceID.uuidString, detachment: detachment)
        MobileHostService.shared.emitClientScopedEvent(topic: Self.mobileDetachedTopic) { clientIDs in
            clientIDs.contains(clientID) ? payload : nil
        }
    }

    /// Adds `size_state` and `self_participant_id` to a replay answer.
    func addSharedSizingReplayFields(to payload: inout [String: Any], surfaceID: UUID, clientID: String?) {
        let coder = TerminalSizingWireCoder()
        if let relay = cloudSizingRelaysBySurfaceID[surfaceID]?.value, relay.relaysPhones {
            if let state = relay.relayedSizeState { payload["size_state"] = coder.jsonObject(state) }
            payload["self_participant_id"] = clientID.flatMap { relay.relayHostParticipantID(clientID: $0) } ?? NSNull()
            return
        }
        guard let host = localSizingHost(surfaceID: surfaceID, create: clientID != nil) else { return }
        payload["size_state"] = coder.jsonObject(host.state)
        let selfID = clientID.map { LocalTerminalSizingHost.phoneParticipantID(clientID: $0) }
        payload["self_participant_id"] = selfID.flatMap { host.state.participant($0) != nil ? $0 : nil } ?? NSNull()
    }

    // MARK: - Detach gate

    /// Whether someone disconnected this phone from the surface.
    func isMobileClientDetached(surfaceID: UUID, clientID: String) -> Bool {
        if cloudDetachedPhonesBySurfaceID[surfaceID]?[clientID] != nil { return true }
        return localSizingHostsBySurfaceID[surfaceID]?
            .isDetached(LocalTerminalSizingHost.phoneParticipantID(clientID: clientID)) ?? false
    }

    private var hasDetachedMobileClients: Bool {
        !cloudDetachedPhonesBySurfaceID.isEmpty
            || localSizingHostsBySurfaceID.values.contains { !$0.detachedPhones.isEmpty }
    }

    func mobileClientDetachedError(surfaceID: UUID, clientID: String) -> V2CallResult? {
        guard isMobileClientDetached(surfaceID: surfaceID, clientID: clientID) else { return nil }
        return .err(
            code: "detached",
            message: "This device was disconnected from the terminal. Reattach to continue.",
            data: ["surface_id": surfaceID.uuidString]
        )
    }

    /// Refuses input, viewport and replay from a disconnected phone and records
    /// input as activity for the latest-input policy.
    func mobileDetachedGateError(method: String, params: [String: Any]) -> V2CallResult? {
        let isInput: Bool
        switch method {
        case "mobile.terminal.input", "terminal.input",
             "mobile.terminal.paste", "terminal.paste",
             "mobile.terminal.paste_image", "terminal.paste_image",
             "mobile.terminal.mouse", "terminal.mouse":
            isInput = true
        case "mobile.terminal.scroll", "terminal.scroll",
             "mobile.terminal.replay", "terminal.replay":
            isInput = false
        default:
            return nil
        }
        guard let clientID = v2String(params, "client_id") else { return nil }
        let needsGate = hasDetachedMobileClients
        guard needsGate || (isInput && (!localSizingHostsBySurfaceID.isEmpty || !cloudSizingRelaysBySurfaceID.isEmpty)) else {
            return nil
        }
        guard let surfaceID = mobileCanonicalTerminalTarget(params: params)?.surfaceID else { return nil }
        if needsGate, let error = mobileClientDetachedError(surfaceID: surfaceID, clientID: clientID) {
            return error
        }
        if isInput { noteMobileSizingActivity(surfaceID: surfaceID, clientID: clientID) }
        return nil
    }

    /// The `counts_override` viewport field: absent leaves it unchanged,
    /// `null` clears it, a boolean sets it.
    func mobileCountsOverrideParam(_ params: [String: Any]) -> Bool?? {
        guard let value = params["counts_override"] else { return nil }
        if value is NSNull { return .some(nil) }
        return (value as? Bool).map { .some($0) }
    }

    // MARK: - Local controller actions

    func localSizingSetPolicy(surfaceID: UUID, policy: TerminalSizingPolicy) -> Bool {
        guard var host = localSizingHostsBySurfaceID[surfaceID] else { return false }
        let previous = host.state
        host.setPolicy(policy)
        localSizingHostsBySurfaceID[surfaceID] = host
        applyLocalSizing(surfaceID: surfaceID, previous: previous, reason: "terminal.size_policy.set")
        return true
    }

    func localSizingSetCountsOverride(surfaceID: UUID, participantID: String, value: Bool?) -> Bool {
        guard var host = localSizingHostsBySurfaceID[surfaceID],
              host.state.participant(participantID) != nil else { return false }
        let previous = host.state
        host.setCountsOverride(participantID, value)
        localSizingHostsBySurfaceID[surfaceID] = host
        applyLocalSizing(surfaceID: surfaceID, previous: previous, reason: "terminal.size_counts.set")
        return true
    }

    func localSizingDisconnect(surfaceID: UUID, participantID: String, by actor: TerminalDetachActor?) -> Bool {
        let prefix = LocalTerminalSizingHost.phoneParticipantID(clientID: "")
        guard var host = localSizingHostsBySurfaceID[surfaceID], participantID.hasPrefix(prefix) else { return false }
        let detachment = TerminalSharingDetachment(
            reason: .disconnectedBy(actor ?? localSizingIdentity().detachActor),
            at: Date()
        )
        let previous = host.state
        guard host.disconnect(participantID, detachment: detachment) else { return false }
        localSizingHostsBySurfaceID[surfaceID] = host
        let clientID = String(participantID.dropFirst(prefix.count))
        emitMobileDetached(surfaceID: surfaceID, clientID: clientID, detachment: detachment)
        // Drop the phone's report so it no longer pins anything; the host
        // refuses its reports until it reattaches.
        _ = clearMobileViewportReport(surfaceID: surfaceID, clientID: clientID, reason: "terminal.participant.disconnect")
        applyLocalSizing(surfaceID: surfaceID, previous: previous, reason: "terminal.participant.disconnect")
        return true
    }

    func localSizingNoteSelfActivity(surfaceID: UUID) {
        noteLocalTerminalSizingActivity(surfaceID: surfaceID)
    }

    // MARK: - Cloud relay registration

    func registerCloudSizingRelay(_ relay: any CloudSizingPhoneRelaying, surfaceID: UUID) {
        ensureTerminalSharingPresentation()
        cloudSizingRelaysBySurfaceID[surfaceID] = CloudSizingRelayReference(value: relay)
        // Phones may already be viewing this mirror: forward them now.
        if let reports = mobileViewportReportsBySurfaceID[surfaceID], !reports.isEmpty {
            relay.relayPhones(phoneParticipants(reports: reports, surfaceID: surfaceID))
        }
    }

    func unregisterCloudSizingRelay(_ relay: any CloudSizingPhoneRelaying, surfaceID: UUID) {
        guard cloudSizingRelaysBySurfaceID[surfaceID]?.value === relay else { return }
        cloudSizingRelaysBySurfaceID[surfaceID] = nil
    }

    /// The Cloud host detached one phone behind this Mac.
    func cloudPhoneDetached(surfaceID: UUID, clientID: String, detachment: TerminalSharingDetachment) {
        cloudPhonesDetached(surfaceID: surfaceID, clientIDs: [clientID], detachment: detachment)
    }

    /// The Cloud host detached phones behind this Mac, one phone's view or
    /// this Mac's own attachment (the phones lose their path with it). Each
    /// gets `mobile.terminal.detached` and its report is dropped; every phone
    /// is marked first so clearing one report never re-relays another.
    func cloudPhonesDetached(surfaceID: UUID, clientIDs: [String], detachment: TerminalSharingDetachment) {
        if !detachment.reason.reconnectsAutomatically {
            for clientID in clientIDs {
                cloudDetachedPhonesBySurfaceID[surfaceID, default: [:]][clientID] = detachment
            }
        }
        for clientID in clientIDs {
            emitMobileDetached(surfaceID: surfaceID, clientID: clientID, detachment: detachment)
            _ = clearMobileViewportReport(surfaceID: surfaceID, clientID: clientID, reason: "cloud.participant.detached")
        }
    }

    // MARK: - Mobile RPC

    /// `mobile.terminal.reattach {surface_id, client_id, as_viewer}`: lifts a
    /// disconnect and answers like `mobile.terminal.replay`.
    func v2MobileTerminalReattach(params: [String: Any]) -> V2CallResult {
        guard let resolved = mobileCanonicalTerminalTarget(params: params) else {
            return .err(code: "not_found", message: "Terminal surface not found", data: nil)
        }
        guard let clientID = v2String(params, "client_id") else {
            return .err(code: "invalid_params", message: "Missing client_id", data: nil)
        }
        let asViewer = v2Bool(params, "as_viewer") ?? false
        let surfaceID = resolved.surfaceID
        cloudDetachedPhonesBySurfaceID[surfaceID]?[clientID] = nil
        if cloudDetachedPhonesBySurfaceID[surfaceID]?.isEmpty == true { cloudDetachedPhonesBySurfaceID[surfaceID] = nil }
        if var host = localSizingHostsBySurfaceID[surfaceID] {
            host.reattach(LocalTerminalSizingHost.phoneParticipantID(clientID: clientID), asViewer: asViewer)
            localSizingHostsBySurfaceID[surfaceID] = host
        }
        var replayParams = params
        if asViewer, cloudSizingRelaysBySurfaceID[surfaceID]?.value?.relaysPhones == true {
            replayParams["counts_override"] = false
        }
        return v2MobileTerminalReplay(params: replayParams)
    }

    /// `mobile.terminal.size_policy.set {surface_id, policy}`.
    func v2MobileTerminalSizePolicySet(params: [String: Any]) -> V2CallResult {
        guard let resolved = mobileCanonicalTerminalTarget(params: params) else {
            return .err(code: "not_found", message: "Terminal surface not found", data: nil)
        }
        guard let policy = TerminalSizingWireCoder().policy(from: params["policy"]) else {
            return .err(code: "invalid_params", message: "Missing or invalid policy", data: nil)
        }
        _ = localSizingHost(surfaceID: resolved.surfaceID, create: true)
        guard terminalSharing.setPolicy(policy, surfaceID: resolved.surfaceID) else {
            return .err(code: "unavailable", message: "Terminal size policy is unavailable", data: nil)
        }
        return .ok(sizeStatePayload(surfaceID: resolved.surfaceID))
    }

    /// `mobile.terminal.participant.disconnect {surface_id, participant_id}`.
    func v2MobileTerminalParticipantDisconnect(params: [String: Any], connectionID: UUID?) -> V2CallResult {
        guard let resolved = mobileCanonicalTerminalTarget(params: params) else {
            return .err(code: "not_found", message: "Terminal surface not found", data: nil)
        }
        guard let participantID = v2String(params, "participant_id") else {
            return .err(code: "invalid_params", message: "Missing participant_id", data: nil)
        }
        let identity = localSizingIdentity()
        let clientID = v2String(params, "client_id")
            ?? connectionID.flatMap { MobileHostService.shared.clientIDs(forConnectionID: $0).sorted().first }
        let deviceName = clientID.flatMap { mobileViewportReportsBySurfaceID[resolved.surfaceID]?[$0]?.deviceName }
        let actor = TerminalDetachActor(userID: identity.userID, displayName: identity.displayName, deviceName: deviceName)
        guard terminalSharing.disconnect(participantID: participantID, surfaceID: resolved.surfaceID, by: actor) else {
            return .err(code: "not_found", message: "Participant not found", data: nil)
        }
        return .ok(sizeStatePayload(surfaceID: resolved.surfaceID))
    }

    // MARK: - Socket / CLI

    func sizeStatePayload(surfaceID: UUID) -> [String: Any] {
        TerminalSizingWireCoder().sizeStatePayload(
            surfaceID: surfaceID.uuidString,
            snapshot: terminalSharing.snapshot(for: surfaceID)
        )
    }

    /// Resolves the terminal a socket request names, making sure a local
    /// terminal has a host so policy commands work before any phone attaches.
    private func sharingSocketSurfaceID(params: [String: Any]) -> UUID? {
        guard let surfaceID = mobileCanonicalTerminalTarget(params: params)?.surfaceID else { return nil }
        if terminalSharing.snapshot(for: surfaceID) == nil {
            _ = localSizingHost(surfaceID: surfaceID, create: true)
        }
        return surfaceID
    }

    private static var sharingSurfaceNotFound: V2CallResult {
        .err(code: "not_found", message: "Terminal surface not found", data: nil)
    }

    /// `terminal.size_state {surface_id?}`.
    func v2TerminalSizeState(params: [String: Any]) -> V2CallResult {
        guard let surfaceID = sharingSocketSurfaceID(params: params) else { return Self.sharingSurfaceNotFound }
        return .ok(sizeStatePayload(surfaceID: surfaceID))
    }

    /// `terminal.size_policy.set {surface_id?, mode?, policy?, fixed_cols?, fixed_rows?, priority?}`.
    func v2TerminalSizePolicySet(params: [String: Any]) -> V2CallResult {
        guard let surfaceID = sharingSocketSurfaceID(params: params),
              let snapshot = terminalSharing.snapshot(for: surfaceID) else { return Self.sharingSurfaceNotFound }
        var policy = TerminalSizingWireCoder().policy(from: params["policy"]) ?? snapshot.state.policy
        if let rawMode = v2String(params, "mode") {
            guard let mode = TerminalSizingMode(rawValue: rawMode) else {
                return .err(code: "invalid_params", message: "Unknown mode \(rawMode)", data: nil)
            }
            policy = policy.withMode(mode, fallbackFixed: snapshot.state.size)
        }
        if let cols = v2Int(params, "fixed_cols"), let rows = v2Int(params, "fixed_rows") {
            policy = TerminalSizingPolicy(mode: policy.mode, priority: policy.priority, fixed: TerminalGridSize(cols: cols, rows: rows))
        }
        if let priority = params["priority"] as? [String] {
            policy = TerminalSizingPolicy(mode: policy.mode, priority: priority, fixed: policy.fixed)
        }
        guard terminalSharing.setPolicy(policy, surfaceID: surfaceID) else {
            return .err(code: "unavailable", message: "Terminal size policy is unavailable", data: nil)
        }
        return .ok(sizeStatePayload(surfaceID: surfaceID))
    }

    /// `terminal.size_to_me {surface_id?}` (Size to My Window).
    func v2TerminalSizeToMe(params: [String: Any]) -> V2CallResult {
        guard let surfaceID = sharingSocketSurfaceID(params: params) else { return Self.sharingSurfaceNotFound }
        guard terminalSharing.sizeToMe(surfaceID: surfaceID) else {
            return .err(code: "unavailable", message: "This window is not attached to the terminal", data: nil)
        }
        return .ok(sizeStatePayload(surfaceID: surfaceID))
    }

    /// `terminal.size_counts.set {surface_id?, participant_id?, counts: bool|null}`.
    func v2TerminalSizeCountsSet(params: [String: Any]) -> V2CallResult {
        guard let surfaceID = sharingSocketSurfaceID(params: params),
              let snapshot = terminalSharing.snapshot(for: surfaceID) else { return Self.sharingSurfaceNotFound }
        guard let participantID = v2String(params, "participant_id") ?? snapshot.selfParticipantID else {
            return .err(code: "invalid_params", message: "Missing participant_id", data: nil)
        }
        let value: Bool? = params["counts"] is NSNull ? nil : v2Bool(params, "counts")
        guard terminalSharing.setCountsOverride(value, participantID: participantID, surfaceID: surfaceID) else {
            return .err(code: "not_found", message: "Participant not found", data: nil)
        }
        return .ok(sizeStatePayload(surfaceID: surfaceID))
    }

    /// `terminal.participant.disconnect {surface_id?, participant_id}`.
    func v2TerminalParticipantDisconnect(params: [String: Any]) -> V2CallResult {
        guard let surfaceID = sharingSocketSurfaceID(params: params) else { return Self.sharingSurfaceNotFound }
        guard let participantID = v2String(params, "participant_id") else {
            return .err(code: "invalid_params", message: "Missing participant_id", data: nil)
        }
        guard terminalSharing.disconnect(participantID: participantID, surfaceID: surfaceID) else {
            return .err(code: "not_found", message: "Participant not found", data: nil)
        }
        return .ok(sizeStatePayload(surfaceID: surfaceID))
    }

    /// `terminal.participants.disconnect_others {surface_id?}`.
    func v2TerminalParticipantsDisconnectOthers(params: [String: Any]) -> V2CallResult {
        guard let surfaceID = sharingSocketSurfaceID(params: params) else { return Self.sharingSurfaceNotFound }
        let count = terminalSharing.disconnectOthers(surfaceID: surfaceID)
        var payload = sizeStatePayload(surfaceID: surfaceID)
        payload["disconnected"] = count
        return .ok(payload)
    }
}
