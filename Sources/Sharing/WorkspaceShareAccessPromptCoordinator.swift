import AppKit
import Foundation

@MainActor
final class WorkspaceShareAccessPromptCoordinator {
    private struct PendingRequest {
        let request: WorkspaceShareAccessRequest
        let completion: @MainActor (Bool) -> Void
    }

    private weak var window: NSWindow?
    private var active: PendingRequest?
    private var queued: [PendingRequest] = []
    private var activeAlert: NSAlert?
    private var sheetObserver: NSObjectProtocol?

    init(window: NSWindow?) {
        self.window = window
    }

    func enqueue(
        _ request: WorkspaceShareAccessRequest,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard active?.request.userId != request.userId,
              !queued.contains(where: { $0.request.userId == request.userId }) else { return }
        let pending = PendingRequest(request: request, completion: completion)
        if active == nil {
            present(pending)
        } else if queued.count < 24 {
            queued.append(pending)
        }
    }

    func cancelAll() {
        let requests = [active].compactMap { $0 } + queued
        active = nil
        queued.removeAll()
        if let sheetObserver {
            NotificationCenter.default.removeObserver(sheetObserver)
            self.sheetObserver = nil
        }
        if let activeAlert {
            if let window, window.attachedSheet === activeAlert.window {
                window.endSheet(activeAlert.window, returnCode: .abort)
            } else {
                activeAlert.window.close()
            }
        }
        activeAlert = nil
        for request in requests { request.completion(false) }
    }

    private func present(_ pending: PendingRequest) {
        active = pending
        if let window, window.isVisible, window.attachedSheet != nil {
            if sheetObserver == nil {
                sheetObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didEndSheetNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if let sheetObserver = self.sheetObserver {
                            NotificationCenter.default.removeObserver(sheetObserver)
                            self.sheetObserver = nil
                        }
                        guard self.active?.request.userId == pending.request.userId else { return }
                        self.present(pending)
                    }
                }
            }
            return
        }
        let alert = NSAlert()
        activeAlert = alert
        alert.alertStyle = .informational
        alert.messageText = String(
            localized: "workspaceShare.access.title",
            defaultValue: "Workspace access request"
        )
        let format = String(
            localized: "workspaceShare.access.message",
            defaultValue: "Display name: %@\nVerified email: %@\n\nAllow access? This lets them view the full workspace and type or run commands in every shared terminal."
        )
        alert.informativeText = String(
            format: format,
            pending.request.displayName,
            pending.request.email
        )
        alert.addButton(withTitle: String(
            localized: "workspaceShare.access.allow",
            defaultValue: "Allow"
        ))
        alert.addButton(withTitle: String(
            localized: "workspaceShare.access.deny",
            defaultValue: "Deny"
        ))
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, self.active?.request.userId == pending.request.userId else { return }
            self.active = nil
            self.activeAlert = nil
            pending.completion(response == .alertFirstButtonReturn)
            self.presentNext()
        }
        if let window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    private func presentNext() {
        guard active == nil, !queued.isEmpty else { return }
        present(queued.removeFirst())
    }
}
