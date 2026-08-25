import AppKit
import CmuxHive
import CmuxHiveUI
import SwiftUI

/// Owns the remote-Mac viewer windows, one per viewed computer.
///
/// Follows the auxiliary-window pattern (`ReleasingWindowController` /
/// `MobilePairingWindowController`): opening the same computer again focuses
/// its existing window instead of spawning a duplicate, and closing the
/// window tears the session down.
@MainActor
final class HiveViewerWindowController: NSObject, NSWindowDelegate {
    static let shared = HiveViewerWindowController()

    /// The viewer windows' shared identifier (identifiers need not be unique
    /// per window). Listed in `cmuxAuxiliaryWindowIdentifiers`
    /// (CmuxAuxiliaryWindows.swift) so Cmd+W closes the viewer instead of a
    /// terminal tab in the main window behind it.
    static let windowIdentifier = "cmux.hiveViewerWindow"

    private final class OpenViewer {
        let window: NSWindow
        var session: HiveRemoteMacSession
        var routeTask: Task<Void, Never>?

        init(window: NSWindow, session: HiveRemoteMacSession) {
            self.window = window
            self.session = session
        }
    }

    private var viewersByDeviceID: [String: OpenViewer] = [:]

    private override init() {
        super.init()
    }

    /// Opens (or focuses) the viewer window for one paired computer.
    func show(deviceID: String) {
        NSApp.activate(ignoringOtherApps: true)
        if let existing = viewersByDeviceID[deviceID] {
            if existing.window.isMiniaturized {
                existing.window.deminiaturize(nil)
            }
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        Task { @MainActor in
            guard let session = await HiveComputersService.shared.makeViewerSession(deviceID: deviceID) else {
                return
            }
            presentWindow(deviceID: deviceID, session: session)
        }
    }

    private func presentWindow(deviceID: String, session: HiveRemoteMacSession) {
        if let existing = viewersByDeviceID[deviceID] {
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        let appearanceMode = UserDefaults.standard.string(forKey: AppearanceSettings.appearanceModeKey)
        let hostingController = NSHostingController(
            rootView: makeRootView(session: session, appearanceMode: appearanceMode)
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = session.displayName
        window.identifier = NSUserInterfaceItemIdentifier(Self.windowIdentifier)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 980, height: 640))
        window.contentMinSize = NSSize(width: 560, height: 360)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        let entry = OpenViewer(window: window, session: session)
        viewersByDeviceID[deviceID] = entry
        entry.routeTask = watchRoutes(deviceID: deviceID, session: session, appearanceMode: appearanceMode)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeRootView(
        session: HiveRemoteMacSession,
        appearanceMode: String?
    ) -> some View {
        HiveViewerRootView(session: session)
            .cmuxAppearanceColorScheme(appearanceMode)
    }

    private func watchRoutes(
        deviceID: String,
        session: HiveRemoteMacSession,
        appearanceMode: String?
    ) -> Task<Void, Never> {
        guard let directory = HiveComputersService.shared.directory else {
            return Task {}
        }
        return Task { @MainActor [weak self] in
            var currentSession = session
            for await computer in directory.updates(for: deviceID) {
                guard let self,
                      let entry = self.viewersByDeviceID[deviceID],
                      entry.session === currentSession else { return }
                guard let computer else {
                    await self.close(deviceID: deviceID)
                    return
                }
                guard computer.isPaired, let best = computer.bestPairingRoutes else {
                    await self.close(deviceID: deviceID)
                    return
                }
                guard best.routes != currentSession.sourceRoutes
                    || best.instanceTag != currentSession.expectedInstanceTag
                    || computer.isRegistryBacked != currentSession.requiresHostIdentity else {
                    continue
                }
                guard let replacement = await HiveComputersService.shared.makeViewerSession(deviceID: deviceID) else {
                    await self.close(deviceID: deviceID)
                    return
                }
                replacement.connect()
                entry.session = replacement
                entry.window.contentViewController = NSHostingController(
                    rootView: self.makeRootView(
                        session: replacement,
                        appearanceMode: appearanceMode
                    )
                )
                await currentSession.disconnect()
                currentSession = replacement
            }
        }
    }

    /// Close a standalone viewer and revoke its remote session, used when a
    /// paired computer is explicitly forgotten from Settings.
    func close(deviceID: String) async {
        guard let entry = viewersByDeviceID.removeValue(forKey: deviceID) else { return }
        entry.routeTask?.cancel()
        entry.routeTask = nil
        entry.window.close()
        await entry.session.disconnect()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let entry = viewersByDeviceID.first(where: { $0.value.window === window }) else { return }
        viewersByDeviceID.removeValue(forKey: entry.key)
        entry.value.routeTask?.cancel()
        let session = entry.value.session
        Task { @MainActor in
            await session.disconnect()
        }
    }

    /// Close every standalone viewer and stop its RPC session during sign-out.
    func closeAll() async {
        let entries = viewersByDeviceID
        viewersByDeviceID.removeAll()
        for entry in entries.values {
            entry.routeTask?.cancel()
            entry.window.close()
            await entry.session.disconnect()
        }
    }
}
