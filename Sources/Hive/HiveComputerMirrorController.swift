import CMUXMobileCore
import CmuxHive
import CmuxMobileRPC
import CmuxSettings
import CmuxTerminal
import AppKit
import Foundation

/// Presents a paired remote Mac's cmux workspaces as NATIVE local mirror
/// workspaces — the remote-tmux mirror recipe pointed at the hive RPC stream.
///
/// Each remote workspace becomes a real sidebar `Workspace` whose tabs are
/// manual-I/O ghostty surfaces: `HiveRemoteTerminalSession` streams
/// render-grid frames, `MobileTerminalRenderGridReplay` turns them into VT
/// bytes fed through `TerminalSurface.processRemoteOutput`, and typed input
/// returns over `mobile.terminal.input`. The result is the exact cmux UI —
/// sidebar rows, tab bar, pane chrome — backed by the other Mac's terminals.
///
/// Topology stays live: the controller consumes the session's
/// `workspaceUpdates()` stream and adds/removes mirror workspaces and
/// terminal tabs as the host's list changes.
@MainActor
final class HiveComputerMirrorController {
    static let shared = HiveComputerMirrorController()
    private init() {}

    /// Mirror ownership is per computer *and* per main-window TabManager.
    /// Two windows may scope to the same computer without stealing each
    /// other's workspaces.
    struct MirrorKey: Hashable, Sendable {
        let deviceID: String
        let tabManagerID: ObjectIdentifier
    }

    private let rebindCoordinator = HiveMirrorRebindCoordinator<MirrorKey>()

    var mirrorsByKey: [MirrorKey: HiveDeviceMirror] = [:]
    var deviceIDByWorkspaceID: [UUID: String] = [:]

    /// Repaints a mirror workspace's terminals from their cached full frames
    /// and re-requests replays. Called when the workspace is selected so a
    /// surface that realized after its replay landed still paints. Scoped to
    /// the selected workspace's terminals only (a device-wide repaint storms
    /// replays on every click).
    func workspaceSelected(_ workspaceId: UUID) {
        for mirror in mirrorsByKey.values {
            guard let remoteWorkspaceID = mirror.workspaceIdByRemoteID
                .first(where: { $0.value == workspaceId })?.key else { continue }
            let terminalIDs = mirror.terminalIDsByRemoteWorkspaceID[remoteWorkspaceID] ?? []
            for terminalID in terminalIDs {
                guard let terminal = mirror.terminalsByRemoteID[terminalID] else { continue }
                if let panelId = mirror.panelIdByRemoteTerminalID[terminalID],
                   let workspace = mirror.tabManager?.workspacesById[workspaceId],
                   let panel = workspace.panels[panelId] as? TerminalPanel {
                    panel.surface.ensureRendererDrawing()
                }
                if let cached = terminal.lastFullFrameBytes {
                    terminal.frameBytesHandler?(cached)
                }
                terminal.refreshReplay()
            }
            return
        }
    }

    /// The device a mirror workspace belongs to, or `nil` for local
    /// workspaces. Drives the sidebar's computer scope filter.
    func deviceID(forWorkspace workspaceId: UUID) -> String? {
        deviceIDByWorkspaceID[workspaceId]
    }

    /// Whether any window currently owns a remote mirror workspace.
    var hasMirrors: Bool {
        !mirrorsByKey.isEmpty
    }

    /// Open a paired computer's viewer honoring the `computers.presentation`
    /// setting. This is the ONE shared action path behind every entrypoint
    /// (Settings "Open" button, sidebar scope picker, `hive.open` RPC):
    /// sidebar mode attaches mirrors into the key main window's sidebar;
    /// windows mode creates a real main window scoped to the device.
    static func presentViewer(deviceID: String) {
        let deviceID = cmxCanonicalDeviceID(deviceID)
        Task { @MainActor in
            guard HiveComputersService.shared.viewerTransportAvailable else { return }
            #if DEBUG
            cmuxDebugLog("hive.presentViewer.begin device=\(deviceID.prefix(8))")
            #endif
            let presentation: ComputersPresentationMode
            if let runtime = AppDelegate.shared?.settingsRuntime {
                presentation = await runtime.jsonStore.value(for: runtime.catalog.computers.presentation)
            } else {
                presentation = .windows
            }
            #if DEBUG
            cmuxDebugLog("hive.presentViewer.mode \(presentation)")
            #endif
            switch presentation {
            case .sidebar:
                guard let appDelegate = AppDelegate.shared,
                      let context = appDelegate.mainWindowContexts.values.first(where: { $0.window?.isKeyWindow == true })
                        ?? appDelegate.mainWindowContexts.values.first(where: { $0.window != nil })
                else {
                    HiveViewerWindowController.shared.show(deviceID: deviceID)
                    return
                }
                // Native mirrors: the computer's workspaces join the main
                // sidebar as real workspaces.
                context.sidebarSelectionState.selection = .tabs
                context.tabManager.hiveSidebarScopeModel.scope = .device(deviceID)
                _ = await HiveComputerMirrorController.shared.attach(
                    deviceID: deviceID,
                    into: context.tabManager
                )
                context.window?.makeKeyAndOrderFront(nil)
            case .windows:
                // A real cmux window scoped to this computer: create a main
                // window, scope its sidebar to the device, attach mirrors.
                guard let appDelegate = AppDelegate.shared else { return }
                let windowId = appDelegate.createMainWindow(shouldActivate: true)
                let context = appDelegate.mainWindowContexts.values.first { $0.windowId == windowId }
                guard let context else {
                    #if DEBUG
                    cmuxDebugLog("hive.presentViewer.windowContextMissing windowId=\(windowId)")
                    #endif
                    return
                }
                context.tabManager.hiveSidebarScopeModel.scope = .device(deviceID)
                let attached = await HiveComputerMirrorController.shared.attach(
                    deviceID: deviceID,
                    into: context.tabManager
                )
                _ = attached
                #if DEBUG
                cmuxDebugLog("hive.presentViewer.attached workspace=\(attached?.uuidString.prefix(8) ?? "nil")")
                #endif
            }
        }
    }

    /// Attaches (or re-focuses) a paired computer's workspaces as native
    /// mirror workspaces in `tabManager`, keeping them reconciled with the
    /// host's live topology.
    @discardableResult
    func attach(
        deviceID: String,
        into tabManager: TabManager,
        replacing expectedMirror: HiveDeviceMirror? = nil
    ) async -> UUID? {
        let deviceID = cmxCanonicalDeviceID(deviceID)
        guard !Task.isCancelled, !tabManager.isFinalizedForWindowClose else { return nil }
        let selectionScope = tabManager.hiveSidebarScopeModel.scope
        let shouldSelect = expectedMirror == nil || selectionScope == .device(deviceID)
            || selectionScope == .allComputers
        let key = MirrorKey(deviceID: deviceID, tabManagerID: ObjectIdentifier(tabManager))
        let previousMirror = mirrorsByKey[key]
        if let expectedMirror, previousMirror !== expectedMirror { return nil }
        if expectedMirror == nil, let existing = previousMirror {
            if let firstId = existing.workspaceIdByRemoteID.values.first,
               let workspace = tabManager.workspacesById[firstId] {
                if tabManager.hiveSidebarScopeModel.scope == selectionScope {
                    tabManager.selectWorkspace(workspace)
                }
                return firstId
            }
        }
        guard let session = await HiveComputersService.shared.embeddedSession(deviceID: deviceID) else {
            #if DEBUG
            cmuxDebugLog("hive.mirror.attach.noSession device=\(deviceID.prefix(8))")
            #endif
            return nil
        }
        guard !Task.isCancelled, !tabManager.isFinalizedForWindowClose else { return nil }
        // A failed session remains cached so every window shares one transport,
        // but an attach from the sidebar Retry action must explicitly restart
        // that failed attempt before rebuilding the mirror around it. New
        // sessions are already connecting; active/reconnecting sessions keep
        // their in-flight lifecycle untouched.
        _ = session.reconnectIfNeeded()
        // Another Open/Retry call may have installed the same mirror while
        // embeddedSession() suspended. Reuse that winner instead of creating
        // an unreachable duplicate with live tasks and workspaces.
        if mirrorsByKey[key] !== previousMirror {
            guard expectedMirror == nil, let winner = mirrorsByKey[key] else { return nil }
            if let firstId = winner.workspaceIdByRemoteID.values.first,
               let workspace = tabManager.workspacesById[firstId] {
                if tabManager.hiveSidebarScopeModel.scope == selectionScope {
                    tabManager.selectWorkspace(workspace)
                }
                return firstId
            }
            return nil
        }
        guard !Task.isCancelled, !tabManager.isFinalizedForWindowClose else { return nil }
        let mirror = HiveDeviceMirror(deviceID: deviceID)
        mirror.tabManager = tabManager
        mirror.computerName = HiveComputersService.shared.directory?.computers
            .first(where: { $0.deviceID == deviceID })?.displayName
            ?? session.displayName
        mirrorsByKey[key] = mirror
        if let window = tabManager.window {
            mirror.windowCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                // Key teardown by the mirror, not by a window context that
                // AppDelegate may unregister during the same close turn.
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.detach(mirrorKey: key)
                }
            }
        }

        if let previousMirror {
            // Transfer ownership before teardown so route churn never resets the user's scope.
            await teardownMirror(
                deviceID: deviceID, mirror: previousMirror, discardEmbeddedSession: false
            )
            guard !Task.isCancelled, mirrorsByKey[key] === mirror,
                  !tabManager.isFinalizedForWindowClose else { return nil }
        }
        mirror.reconcileTask = Task { @MainActor [weak self, weak mirror] in
            for await workspaces in session.workspaceUpdates() {
                guard let self, let mirror else { return }
                self.reconcile(remote: workspaces, mirror: mirror, session: session)
            }
        }
        if let directory = HiveComputersService.shared.directory {
            mirror.routeTask = Task { @MainActor [weak self, weak mirror, weak tabManager] in
                for await computer in directory.updates(for: deviceID) {
                    guard let self, let mirror, let tabManager else { return }
                    let key = MirrorKey(
                        deviceID: deviceID,
                        tabManagerID: ObjectIdentifier(tabManager)
                    )
                    guard self.mirrorsByKey[key] === mirror else { return }
                    guard let computer else {
                        await self.detach(deviceID: deviceID, from: tabManager)
                        return
                    }
                    guard computer.isPaired, let best = computer.bestPairingRoutes else {
                        await self.detach(deviceID: deviceID, from: tabManager)
                        return
                    }
                    guard best.routes != session.sourceRoutes
                        || best.instanceTag != session.expectedInstanceTag
                        || computer.isRegistryBacked != session.requiresHostIdentity else {
                        continue
                    }
                    // The replacement must outlive cancellation of this obsolete observer.
                    self.rebindCoordinator.rebind(key: key) { [weak self, weak mirror, weak tabManager] in
                        guard let self, let mirror, let tabManager else { return }
                        _ = await self.attach(
                            deviceID: deviceID, into: tabManager, replacing: mirror
                        )
                    }
                    return
                }
            }
        }

        // The deadline only bounds an empty attachment; readiness comes from reconciliation.
        let firstID = await mirror.workspaceReadiness.wait {
            try? await ContinuousClock().sleep(for: .seconds(10))
        }
        guard !Task.isCancelled, !tabManager.isFinalizedForWindowClose, mirrorsByKey[key] === mirror,
              let firstID, let workspace = tabManager.workspacesById[firstID] else { return nil }
        if shouldSelect, tabManager.hiveSidebarScopeModel.scope == selectionScope {
            tabManager.selectWorkspace(workspace)
        }
        return firstID
    }

    /// Detaches a computer's mirrors: stops the streams and closes the
    /// mirror workspaces.
    func detach(deviceID: String, from tabManager: TabManager) async {
        let deviceID = cmxCanonicalDeviceID(deviceID)
        let key = MirrorKey(deviceID: deviceID, tabManagerID: ObjectIdentifier(tabManager))
        rebindCoordinator.cancel(key: key)
        guard let mirror = mirrorsByKey.removeValue(forKey: key) else { return }
        let shouldDiscard = !mirrorsByKey.keys.contains { $0.deviceID == deviceID }
        await teardownMirror(deviceID: deviceID, mirror: mirror, discardEmbeddedSession: shouldDiscard)
    }

    private func detach(mirrorKey key: MirrorKey) async {
        rebindCoordinator.cancel(key: key)
        guard let mirror = mirrorsByKey.removeValue(forKey: key) else { return }
        let shouldDiscard = !mirrorsByKey.keys.contains { $0.deviceID == key.deviceID }
        await teardownMirror(
            deviceID: key.deviceID,
            mirror: mirror,
            discardEmbeddedSession: shouldDiscard
        )
    }

    /// Tear down every embedded mirror, used when account auth ends.
    func detachAll() async {
        rebindCoordinator.cancelAll()
        let mirrors = Array(mirrorsByKey.values)
        mirrorsByKey.removeAll()
        var deviceIDs = Set<String>()
        for mirror in mirrors {
            deviceIDs.insert(mirror.deviceID)
            await teardownMirror(
                deviceID: mirror.deviceID,
                mirror: mirror,
                discardEmbeddedSession: false
            )
        }
        for deviceID in deviceIDs {
            await HiveComputersService.shared.discardEmbeddedSession(deviceID: deviceID)
        }
    }

    /// Tear down one device's mirror regardless of which window owns it.
    func detach(deviceID: String) async {
        let deviceID = cmxCanonicalDeviceID(deviceID)
        rebindCoordinator.cancelAll { $0.deviceID == deviceID }
        let keys = mirrorsByKey.keys.filter { $0.deviceID == deviceID }
        guard !keys.isEmpty else { return }
        let mirrors = keys.compactMap { mirrorsByKey.removeValue(forKey: $0) }
        for mirror in mirrors {
            await teardownMirror(deviceID: deviceID, mirror: mirror, discardEmbeddedSession: false)
        }
        await HiveComputersService.shared.discardEmbeddedSession(deviceID: deviceID)
    }

    private func teardownMirror(
        deviceID: String,
        mirror: HiveDeviceMirror,
        discardEmbeddedSession: Bool
    ) async {
        mirror.workspaceReadiness.finish()
        mirror.reconcileTask?.cancel()
        mirror.reconcileTask = nil
        mirror.routeTask?.cancel()
        mirror.routeTask = nil
        if let observer = mirror.windowCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            mirror.windowCloseObserver = nil
        }
        for (_, terminal) in mirror.terminalsByRemoteID { terminal.detach() }
        if let tabManager = mirror.tabManager {
            let hasSurvivingMirror = mirrorsByKey.values.contains {
                $0 !== mirror && $0.tabManager === tabManager
            }
            if !hasSurvivingMirror,
               case .device(let scopedDeviceID) = tabManager.hiveSidebarScopeModel.scope,
               scopedDeviceID == deviceID {
                tabManager.hiveSidebarScopeModel.scope = .thisMac
            }
            for (_, workspaceId) in mirror.workspaceIdByRemoteID {
                deviceIDByWorkspaceID.removeValue(forKey: workspaceId)
                guard let workspace = tabManager.workspacesById[workspaceId] else { continue }
                tabManager.closeWorkspace(workspace)
            }
        }
        if mirror.tabManager == nil {
            for workspaceId in mirror.workspaceIdByRemoteID.values {
                deviceIDByWorkspaceID.removeValue(forKey: workspaceId)
            }
        }
        mirror.terminalsByRemoteID.removeAll()
        mirror.workspaceIdByRemoteID.removeAll()
        mirror.panelIdByRemoteTerminalID.removeAll()
        mirror.terminalIDsByRemoteWorkspaceID.removeAll()
        if discardEmbeddedSession {
            await HiveComputersService.shared.discardEmbeddedSession(deviceID: deviceID)
        }
    }

}
