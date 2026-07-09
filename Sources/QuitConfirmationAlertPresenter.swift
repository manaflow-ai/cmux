import AppKit

@MainActor
final class QuitConfirmationAlertPresenter: NSObject, NSWindowDelegate {
    typealias Completion = (NSApplication.ModalResponse, NSControl.StateValue) -> Void

    private let alert: NSAlert
    private let presentingWindowProvider: () -> NSWindow?
    private let completion: Completion
    private var didFinish = false

    init(
        alert: NSAlert? = nil,
        presentingWindowProvider: (() -> NSWindow?)? = nil,
        completion: @escaping Completion
    ) {
        self.alert = alert ?? Self.makeAlert()
        self.presentingWindowProvider = presentingWindowProvider ?? { cmuxMainWindowForModalPresentation() }
        self.completion = completion
        super.init()
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
        let buttons = alert.buttons
        if buttons.indices.contains(0) {
            buttons[0].target = self
            buttons[0].action = #selector(confirmQuit)
        }
        if buttons.indices.contains(1) {
            buttons[1].target = self
            buttons[1].action = #selector(cancelQuit)
        }

        let window = alert.window
        window.delegate = self
        window.level = .modalPanel
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func confirmQuit() {
        finish(.alertFirstButtonReturn)
    }

    @objc private func cancelQuit() {
        finish(.alertSecondButtonReturn)
    }

    func windowWillClose(_ notification: Notification) {
        finish(.alertSecondButtonReturn)
    }

    private func finish(_ response: NSApplication.ModalResponse) {
        guard !didFinish else { return }
        didFinish = true
        alert.window.delegate = nil
        alert.window.orderOut(nil)
        completion(response, alert.suppressionButton?.state ?? .off)
    }
}

extension AppDelegate {
    static func pendingTerminateReply(
        isAwaitingTerminateKills: Bool,
        hasActiveQuitConfirmation: Bool,
        activeQuitConfirmationOwnsTerminateRequest: Bool
    ) -> NSApplication.TerminateReply? {
        if isAwaitingTerminateKills { return .terminateLater }
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

        if registeredMainWindows.contains(where: { managerHasDirtyWorkspace($0.tabManager) }) {
            return true
        }
        if managerHasDirtyWorkspace(tabManager) {
            return true
        }
        return recoverableMainWindowRoutes().contains { managerHasDirtyWorkspace($0.tabManager) }
    }
}
