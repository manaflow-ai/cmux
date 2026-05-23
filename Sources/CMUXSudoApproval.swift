import AppKit
import Foundation
import LocalAuthentication

struct CMUXSudoApprovalResult: Sendable {
    let approved: Bool
    let reason: String?
}

enum CMUXSudoApprovalPresenter {
    @MainActor
    static func requestApproval(_ request: CMUXSudoCommandRequest) async -> CMUXSudoApprovalResult {
#if DEBUG
        if let override = CMUXSudoTestHooks.approvalOverride {
            return override(request)
        }
#endif
        guard let window = workspaceWindow(for: request) else {
            return .init(
                approved: false,
                reason: String(localized: "sudo.error.surfaceInactive", defaultValue: "workspace or terminal surface is not active")
            )
        }
        notifyWorkspace(for: request)

        let alert = NSAlert()
        alert.messageText = String(
            localized: "sudo.prompt.title",
            defaultValue: "Approve sudo command?"
        )
        alert.informativeText = String(
            localized: "sudo.prompt.message",
            defaultValue: "cmux will authenticate you before sending this exact command to the privileged helper."
        )
        alert.addButton(withTitle: String(localized: "sudo.prompt.authenticate", defaultValue: "Authenticate"))
        alert.addButton(withTitle: String(localized: "sudo.prompt.deny", defaultValue: "Deny"))
        alert.accessoryView = commandAccessoryView(for: request.displayCommand)

        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { modalResponse in
                continuation.resume(returning: modalResponse)
            }
        }
        guard response == .alertFirstButtonReturn else {
            return .init(
                approved: false,
                reason: String(localized: "sudo.denied.byUser", defaultValue: "User denied the sudo request")
            )
        }

        let context = LAContext()
        context.localizedCancelTitle = String(localized: "sudo.auth.cancel", defaultValue: "Cancel")

        var evaluationError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &evaluationError) else {
            return .init(
                approved: false,
                reason: String(
                    localized: "sudo.auth.unavailable",
                    defaultValue: "Device owner authentication is unavailable"
                )
            )
        }

        let reasonFormat = String(
            localized: "sudo.auth.reason",
            defaultValue: "Approve cmux sudo command: %@"
        )
        let reason = String.localizedStringWithFormat(reasonFormat, request.displayCommand)
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(
                    returning: .init(
                        approved: success,
                        reason: success ? nil : String(localized: "sudo.auth.failed", defaultValue: "Authentication failed")
                    )
                )
            }
        }
    }

    @MainActor
    private static func workspaceWindow(for request: CMUXSudoCommandRequest) -> NSWindow? {
        guard let app = AppDelegate.shared else { return nil }
        for summary in app.listMainWindowSummaries() {
            guard let tabManager = app.tabManagerFor(windowId: summary.windowId),
                  tabManager.tabs.contains(where: { $0.id == request.workspaceID }) else {
                continue
            }
            return app.windowForMainWindowId(summary.windowId)
        }
        return nil
    }

    @MainActor
    private static func notifyWorkspace(for request: CMUXSudoCommandRequest) {
        let title = String(localized: "sudo.prompt.title", defaultValue: "Approve sudo command?")
        let body = String(
            localized: "sudo.prompt.message",
            defaultValue: "cmux will authenticate you before sending this exact command to the privileged helper."
        )
        TerminalNotificationStore.shared.addNotification(
            tabId: request.workspaceID,
            surfaceId: request.surfaceID,
            title: title,
            subtitle: request.displayCommand,
            body: body,
            cooldownKey: "sudo.request.\(request.requestID)",
            cooldownInterval: 60
        )
    }

    @MainActor
    private static func commandAccessoryView(for command: String) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: String(localized: "sudo.prompt.command", defaultValue: "Command"))
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        let commandView = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 140))
        commandView.string = command
        commandView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        commandView.textColor = .labelColor
        commandView.backgroundColor = .textBackgroundColor
        commandView.isEditable = false
        commandView.isSelectable = true
        commandView.isRichText = false
        commandView.textContainerInset = NSSize(width: 6, height: 6)
        commandView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder
        scrollView.documentView = commandView
        scrollView.widthAnchor.constraint(equalToConstant: 520).isActive = true
        scrollView.heightAnchor.constraint(equalToConstant: 140).isActive = true

        stack.addArrangedSubview(label)
        if let cwd = request.cwd, !cwd.isEmpty {
            let cwdLabel = NSTextField(labelWithString: String(localized: "sudo.prompt.workingDirectory", defaultValue: "Working directory"))
            cwdLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

            let cwdField = NSTextField(labelWithString: cwd)
            cwdField.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize)
            cwdField.textColor = .secondaryLabelColor
            cwdField.lineBreakMode = .byTruncatingMiddle
            cwdField.maximumNumberOfLines = 1
            cwdField.widthAnchor.constraint(equalToConstant: 520).isActive = true
            stack.addArrangedSubview(cwdLabel)
            stack.addArrangedSubview(cwdField)
        }
        stack.addArrangedSubview(scrollView)
        return stack
    }
}
