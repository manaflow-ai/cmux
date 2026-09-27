import AppKit
import SwiftUI

/// Shows one ``CloudCreateTeamSheet`` at a time as a sheet on the main cmux
/// window, or as a floating window when no main window can host it.
@MainActor
final class CloudCreateTeamSheetPresenter {
    static let shared = CloudCreateTeamSheetPresenter()

    private var sheetWindow: NSWindow?
    private var hostWindow: NSWindow?

    private init() {}

    /// A second request while the sheet is up re-raises it instead of stacking.
    func present(accountFlow: HostAccountFlow, preferredWindow: NSWindow? = nil) {
        if let sheetWindow {
            (hostWindow ?? sheetWindow).makeKeyAndOrderFront(nil)
            return
        }
        let controller = NSHostingController(rootView: CloudCreateTeamSheet(
            accountFlow: accountFlow,
            onFinish: { [weak self] in self?.dismiss() }
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
            host.beginSheet(window) { _ in }
        } else {
            // Cancel is the only way out, so no close button can leave the
            // presenter holding a window nobody sees.
            hostWindow = nil
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func dismiss() {
        guard let window = sheetWindow else { return }
        if let host = hostWindow, host.attachedSheet === window {
            host.endSheet(window)
        }
        window.orderOut(nil)
        sheetWindow = nil
        hostWindow = nil
    }
}
