import AppKit
import SwiftUI

/// Shows one ``CloudCreateTeamSheet`` at a time for the Cloud surface that owns
/// it, as a sheet on the main cmux window, or as a floating window when no main
/// window can host it.
@MainActor
final class CloudCreateTeamSheetPresenter: NSObject, NSWindowDelegate {
    private let resolveHostWindow: @MainActor (NSWindow?) -> NSWindow?
    private var sheetWindow: NSWindow?
    private weak var hostWindow: NSWindow?
    /// Identifies the current sheet, so a late finish from an earlier sheet
    /// cannot close this one.
    private var sessionID: UUID?

    init(resolveHostWindow: @escaping @MainActor (NSWindow?) -> NSWindow? = {
        NSApp.cmuxMainWindowForModalPresentation(preferring: $0)
    }) {
        self.resolveHostWindow = resolveHostWindow
        super.init()
    }

    /// A second request while the sheet is up re-raises it instead of stacking.
    /// `onCreate` gets the entered name after the sheet closes, once per sheet.
    func present(
        accountFlow: HostAccountFlow,
        initialName: String = "",
        preferredWindow: NSWindow? = nil,
        onCreate: @escaping (String) -> Void
    ) {
        if let sheetWindow {
            if sheetWindow.isVisible || hostWindow?.attachedSheet === sheetWindow {
                (hostWindow ?? sheetWindow).makeKeyAndOrderFront(nil)
                return
            }
            // The sheet went away without Cancel or Create, for example with
            // its host window. Start over instead of raising a hidden window,
            // and order the old one out so it cannot come back beside the new.
            sheetWindow.orderOut(nil)
            reset()
        }
        let sessionID = UUID()
        self.sessionID = sessionID
        // The open sheet holds its presenter, so Cancel still closes it after
        // the Cloud surface that opened it is gone. `reset()` releases the
        // window when the sheet ends, which breaks the cycle.
        // Return can reach both the field and the default button, so only
        // the call that closes the sheet creates a team.
        let controller = NSHostingController(rootView: CloudCreateTeamSheet(
            accountFlow: accountFlow,
            initialName: initialName,
            onCreate: { [self] name in
                guard dismiss(sessionID) else { return }
                onCreate(name)
            },
            onCancel: { [self] in dismiss(sessionID) }
        ))
        controller.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable]
        window.identifier = NSUserInterfaceItemIdentifier("cmux.cloudCreateTeam")
        window.delegate = self
        window.title = String(localized: "cloud.teamPicker.createSheet.title", defaultValue: "Create Team")
        window.isReleasedWhenClosed = false
        sheetWindow = window

        let host = resolveHostWindow(preferredWindow ?? NSApp.keyWindow)
        if let host, host.attachedSheet == nil {
            hostWindow = host
            host.beginSheet(window) { [self] _ in
                // Also runs when AppKit ends the sheet on its own.
                dismiss(sessionID)
            }
        } else {
            // The window delegate sends the close button and Close shortcut
            // through the same session cleanup as Cancel.
            hostWindow = nil
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Returns whether this call closed the sheet.
    @discardableResult
    private func dismiss(_ sessionID: UUID) -> Bool {
        guard sessionID == self.sessionID, let window = sheetWindow else { return false }
        let host = hostWindow
        reset()
        if let host, host.attachedSheet === window {
            host.endSheet(window)
        }
        window.orderOut(nil)
        return true
    }

    private func reset() {
        sheetWindow = nil
        hostWindow = nil
        sessionID = nil
    }

    func windowShouldClose(_ window: NSWindow) -> Bool {
        guard window === sheetWindow, let sessionID else { return true }
        _ = dismiss(sessionID)
        return false
    }
}
