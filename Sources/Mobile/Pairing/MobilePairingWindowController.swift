import AppKit
import Bonsplit
import CmuxWorkspaces
import SwiftUI

/// Owns the single iOS pairing window and presents it on demand.
///
/// Mirrors the host-side config window pattern: it reuses the existing window
/// when one is already open (so repeated requests focus instead of spawning
/// duplicates) and hosts ``MobilePairingView`` in an `NSHostingController`.
@MainActor
final class MobilePairingWindowController: ReleasingWindowController {
    /// The shared controller. The app target composes window controllers as
    /// singletons (see the task-manager and debug windows).
    static let shared = MobilePairingWindowController()

    /// The pairing window's identifier. Listed in
    /// `cmuxAuxiliaryWindowIdentifiers` (CmuxAuxiliaryWindows.swift) so the standard close
    /// shortcut closes this window instead of a terminal tab in the main
    /// window behind it; referenced from the Cmd+W regression test.
    static let windowIdentifier = "cmux.mobilePairingWindow"

    private static let screenMargin: CGFloat = 40
    private var idealContentHeight: CGFloat?
    private var isUserResizing = false

    private override init() {
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Brings the pairing window to the front, creating it if needed.
    func show() {
        NSApp.activate(ignoringOtherApps: true)

        let window = managedWindow()
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        if !window.isVisible {
            window.center()
        }
        resizeWindowToIdealContentHeight(window)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    override func makeWindow() -> NSWindow {
        let appearanceMode = UserDefaults.standard.string(forKey: AppearanceSettings.appearanceModeKey)
        let root = MobilePairingView { [weak self] height in
            self?.pairingContentHeightDidChange(height)
        }
            .cmuxAppearanceColorScheme(appearanceMode)
        let hostingController = NSHostingController(rootView: root)

        let window = NSWindow(contentViewController: hostingController)
        window.title = String(localized: "mobile.pairing.window.title", defaultValue: "Tailscale Pairing")
        window.identifier = NSUserInterfaceItemIdentifier(Self.windowIdentifier)
        // Resizable so the QR (which fills the window width) can be made even
        // larger for scanning at a distance.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // Tall enough that the title, the manual-entry block, and the whole QR
        // are visible without scrolling out of the box; the 540x720 default
        // clipped the heading and pushed Copy IP/Port below the fold in
        // dogfood. The minimum keeps the QR plus the manual block usable on
        // small screens.
        window.setContentSize(NSSize(width: 560, height: 800))
        window.contentMinSize = NSSize(width: 480, height: 320)
        window.center()
        return window
    }

    override func managedWindowWillClose(_ window: NSWindow) {
        idealContentHeight = nil
        isUserResizing = false
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        isUserResizing = true
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        isUserResizing = false
    }

    private func pairingContentHeightDidChange(_ height: CGFloat) {
        guard height > 0 else { return }
        idealContentHeight = ceil(height)
        guard !isUserResizing, let window else { return }
        resizeWindowToIdealContentHeight(window)
    }

    /// Keeps the current width and top edge, growing downward until the screen
    /// margin would be crossed, then shifts the window up just enough to fit.
    private func resizeWindowToIdealContentHeight(_ window: NSWindow) {
        guard !isUserResizing,
              let idealContentHeight,
              let screen = window.screen ?? NSScreen.main else { return }

        let visibleFrame = screen.visibleFrame.insetBy(
            dx: 0,
            dy: Self.screenMargin / 2
        )
        let contentChromeHeight = window.frame.height - window.contentLayoutRect.height
        // setFrame(_:display:) does not enforce contentMinSize, so clamp here
        // or a small in-flight measurement (e.g. the loading spinner) could
        // shrink the window below the usable floor.
        let minContentHeight = window.contentMinSize.height
        let targetFrameHeight = min(
            max(idealContentHeight, minContentHeight) + contentChromeHeight,
            visibleFrame.height
        )
        guard targetFrameHeight > 0 else { return }

        var targetFrame = window.frame
        targetFrame.origin.y = targetFrame.maxY - targetFrameHeight
        targetFrame.size.height = targetFrameHeight
        if targetFrame.minY < visibleFrame.minY {
            targetFrame.origin.y = visibleFrame.minY
        }
        if targetFrame.maxY > visibleFrame.maxY {
            targetFrame.origin.y = visibleFrame.maxY - targetFrameHeight
        }
        window.setFrame(targetFrame, display: true)
    }
}

/// Workspace-owned pane for the Tailscale pairing flow.
@MainActor
final class MobilePairingPanel: Panel {
    let id = UUID()
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .mobilePairing

    var displayTitle: String {
        String(localized: "mobile.pairing.window.title", defaultValue: "Tailscale Pairing")
    }

    var displayIcon: String? { "iphone" }

    func focus() {}
    func unfocus() {}
    func close() {}
    func triggerFlash(reason: WorkspaceAttentionFlashReason) { _ = reason }
}

struct MobilePairingPanelView: View {
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    var body: some View {
        MobilePairingView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: appearance.contentBackgroundColor))
            .environment(\.colorScheme, appearance.backgroundColor.isLightColor ? .light : .dark)
            .contentShape(Rectangle())
            .onTapGesture { onRequestPanelFocus() }
            .accessibilityIdentifier("MobilePairingPanel")
    }
}

extension Workspace {
    @discardableResult
    func newMobilePairingSurface(inPane paneId: PaneID, focus: Bool = true) -> MobilePairingPanel? {
        let panel = MobilePairingPanel()
        panels[panel.id] = panel
        panelTitles[panel.id] = panel.displayTitle

        guard let tabId = bonsplitController.createTab(
            title: panel.displayTitle,
            icon: panel.displayIcon,
            kind: SurfaceKind.mobilePairing.rawValue,
            isDirty: false,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: panel.id)
            panelTitles.removeValue(forKey: panel.id)
            return nil
        }

        bindSurface(tabId, toPanelId: panel.id)
        publishCmuxSurfaceCreated(
            panel.id,
            paneId: paneId,
            kind: SurfaceKind.mobilePairing.rawValue,
            origin: "mobile_pairing_workspace",
            focused: focus
        )
        if focus {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(tabId)
            applyTabSelection(tabId: tabId, inPane: paneId)
        }
        return panel
    }
}
