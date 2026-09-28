import AppKit
import SwiftUI

/// Shows one ``CloudCreateTeamSheet`` at a time as a sheet on the main cmux
/// window, or as a floating window when no main window can host it.
@MainActor
final class CloudCreateTeamSheetPresenter {
    static let shared = CloudCreateTeamSheetPresenter()

    private var sheetWindow: NSWindow?
    private weak var hostWindow: NSWindow?
    /// Identifies the current sheet, so a late finish from an earlier sheet
    /// cannot close this one.
    private var sessionID: UUID?

    private init() {}

    /// A second request while the sheet is up re-raises it instead of stacking.
    func present(accountFlow: HostAccountFlow, preferredWindow: NSWindow? = nil) {
        if let sheetWindow {
            if sheetWindow.isVisible || hostWindow?.attachedSheet === sheetWindow {
                (hostWindow ?? sheetWindow).makeKeyAndOrderFront(nil)
                return
            }
            // The sheet went away without Cancel or Create, for example with
            // its host window. Start over instead of raising a hidden window.
            reset()
        }
        let sessionID = UUID()
        self.sessionID = sessionID
        let controller = NSHostingController(rootView: CloudCreateTeamSheet(
            accountFlow: accountFlow,
            onFinish: { [weak self] in self?.dismiss(sessionID) }
        ))
        controller.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled]
        window.title = String(localized: "cloud.teamPicker.createSheet.title", defaultValue: "Create Team")
        window.isReleasedWhenClosed = false
        sheetWindow = window

        let host = NSApp.cmuxMainWindowForModalPresentation(preferring: preferredWindow ?? NSApp.keyWindow)
        if let host, host.attachedSheet == nil {
            hostWindow = host
            host.beginSheet(window) { [weak self] _ in
                // Also runs when AppKit ends the sheet on its own.
                self?.dismiss(sessionID)
            }
        } else {
            // Cancel is the only way out, so no close button can leave the
            // presenter holding a window nobody sees.
            hostWindow = nil
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func dismiss(_ sessionID: UUID) {
        guard sessionID == self.sessionID, let window = sheetWindow else { return }
        let host = hostWindow
        reset()
        if let host, host.attachedSheet === window {
            host.endSheet(window)
        }
        window.orderOut(nil)
    }

    private func reset() {
        sheetWindow = nil
        hostWindow = nil
        sessionID = nil
    }
}
