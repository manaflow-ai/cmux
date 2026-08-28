import AppKit

@MainActor
final class QuitConfirmationAlertPresenter: NSObject, NSWindowDelegate {
    typealias Completion = (NSApplication.ModalResponse, NSControl.StateValue) -> Void

    private let alert: NSAlert
    private let presentingWindowProvider: () -> NSWindow?
    private let completion: Completion
    /// The response that means "do not quit". Second button for the default
    /// two-button alert; the cmux-tui keep/stop alert passes its third button.
    private let cancelResponse: NSApplication.ModalResponse
    private var didFinish = false
    private var joinedCancellationAction: (() -> Void)?

    init(
        alert: NSAlert? = nil,
        cancelResponse: NSApplication.ModalResponse = .alertSecondButtonReturn,
        presentingWindowProvider: (() -> NSWindow?)? = nil,
        completion: @escaping Completion
    ) {
        self.alert = alert ?? Self.makeAlert()
        self.cancelResponse = cancelResponse
        self.presentingWindowProvider = presentingWindowProvider ?? {
            NSApp.cmuxMainWindowForModalPresentation()
        }
        self.completion = completion
        super.init()
    }

    func joinCancellationAction(_ action: @escaping () -> Void) {
        guard !didFinish else { return }
        // Only one sole-terminal recovery can be relevant while this decision
        // is open. Replacing the action coalesces duplicate child-exit delivery.
        joinedCancellationAction = action
    }

    private static func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "dialog.quitCmux.title", defaultValue: "Quit cmux?")
        alert.informativeText = String(localized: "dialog.quitCmux.message", defaultValue: "This will close all windows and workspaces.")
        alert.addButton(withTitle: String(localized: "dialog.quitCmux.quit", defaultValue: "Quit"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "dialog.dontWarnCmdQ", defaultValue: "Don't warn again for Cmd+Q")
        return alert
    }

    func present() {
        if NSApp.activationPolicy() == .regular {
            NSApp.activate(ignoringOtherApps: true)
        }

        if let hostWindow = presentingWindowProvider(), hostWindow.attachedSheet == nil {
            alert.beginSheetModal(for: hostWindow) { [weak self] response in
                self?.finish(response)
            }
            return
        }

        presentStandalone()
    }

    private func presentStandalone() {
        alert.layout()

        // AppKit assigns each alert button a tag of alertFirstButtonReturn + index.
        // Wire every button generically: the tui keep-vs-stop quit dialog has
        // three buttons, not the fixed confirm/cancel pair.
        for button in alert.buttons {
            button.target = self
            button.action = #selector(alertButtonClicked(_:))
        }

        let window = alert.window
        window.delegate = self
        window.level = .modalPanel
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func alertButtonClicked(_ sender: NSButton) {
        finish(NSApplication.ModalResponse(rawValue: sender.tag))
    }

    func windowWillClose(_ notification: Notification) {
        finish(cancelResponse)
    }

    private func finish(_ response: NSApplication.ModalResponse) {
        guard !didFinish else { return }
        didFinish = true
        let cancellationAction = joinedCancellationAction
        joinedCancellationAction = nil
        alert.window.delegate = nil
        alert.window.orderOut(nil)
        completion(response, alert.suppressionButton?.state ?? .off)
        if response == cancelResponse {
            cancellationAction?()
        }
    }
}

extension AppDelegate {
    static func pendingTerminateReply(
        isAwaitingTerminateCleanup: Bool,
        hasActiveQuitConfirmation: Bool,
        activeQuitConfirmationOwnsTerminateRequest: Bool
    ) -> NSApplication.TerminateReply? {
        if isAwaitingTerminateCleanup { return .terminateLater }
        guard hasActiveQuitConfirmation else { return nil }
        return activeQuitConfirmationOwnsTerminateRequest ? .terminateLater : .terminateCancel
    }

    func hasQuitConfirmationDirtyWorkspaces() -> Bool {
        // Per-window Docks die with their windows (and with the app), so their
        // busy terminals count toward the quit warning exactly like a
        // workspace Dock's do via `Workspace.needsConfirmClose()`.
        if existingWindowDocks.contains(where: { $0.needsConfirmClose() }) {
            return true
        }

        var visitedManagers = Set<ObjectIdentifier>()

        func managerHasDirtyWorkspace(_ manager: TabManager?) -> Bool {
            guard let manager else { return false }
            let managerId = ObjectIdentifier(manager)
            guard visitedManagers.insert(managerId).inserted else { return false }
            return manager.tabs.contains(where: { $0.needsConfirmClose() })
        }

        if mainWindowContexts.values.contains(where: { managerHasDirtyWorkspace($0.tabManager) }) {
            return true
        }
        if managerHasDirtyWorkspace(tabManager) {
            return true
        }
        // Quit confirmation is a lifecycle/data-safety check, so it must include
        // windowless recoverable owners that UI-routing snapshots intentionally hide.
        return mainWindowSessionPersistenceRoutes().contains { managerHasDirtyWorkspace($0.tabManager) }
    }
}
