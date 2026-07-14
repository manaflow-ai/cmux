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

    private struct OpenViewer {
        let window: NSWindow
        let session: HiveRemoteMacSession
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
        let root = HiveViewerRootView(session: session)
            .cmuxAppearanceColorScheme(appearanceMode)
        let hostingController = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hostingController)
        window.title = session.displayName
        window.identifier = NSUserInterfaceItemIdentifier(Self.windowIdentifier)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 980, height: 640))
        window.contentMinSize = NSSize(width: 560, height: 360)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        viewersByDeviceID[deviceID] = OpenViewer(window: window, session: session)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let entry = viewersByDeviceID.first(where: { $0.value.window === window }) else { return }
        viewersByDeviceID.removeValue(forKey: entry.key)
        let session = entry.value.session
        Task { @MainActor in
            await session.disconnect()
        }
    }
}
