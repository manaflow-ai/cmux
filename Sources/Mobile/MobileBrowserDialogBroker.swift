import CMUXMobileCore
import Foundation

/// Owns panel-wide native browser dialog completions and arbitrates Mac/phone answers.
@MainActor
final class MobileBrowserDialogBroker {
    typealias Resolver = @MainActor (_ buttonID: String, _ text: String?) -> Void
    typealias Dismissal = @MainActor () -> Void

    private struct PendingResolution {
        let resolve: Resolver
        var dismiss: Dismissal?
    }

    let panelID: String
    var onPresented: (@MainActor (MobileBrowserDialogEvent) -> Void)?
    var onResolved: (@MainActor (MobileBrowserDialogResolvedEvent) -> Void)?

    private var queue = MobileBrowserDialogQueue()
    private var resolutions: [String: PendingResolution] = [:]

    init(panelID: String) {
        self.panelID = panelID
    }

    var currentDialog: MobileBrowserDialogEvent? { queue.current }

    @discardableResult
    func begin(
        kind: MobileBrowserDialogKind,
        title: String?,
        message: String?,
        host: String?,
        buttons: [MobileBrowserDialogButton],
        textField: MobileBrowserDialogTextField?,
        informational: Bool,
        resolve: @escaping Resolver
    ) -> MobileBrowserDialogEvent {
        let shouldPublish = queue.current == nil
        let dialog = MobileBrowserDialogEvent(
            panelID: panelID,
            dialogID: UUID().uuidString,
            kind: kind,
            title: title,
            message: message,
            host: host,
            buttons: buttons,
            textField: textField,
            informational: informational
        )
        _ = queue.install(dialog)
        resolutions[dialog.dialogID] = PendingResolution(resolve: resolve, dismiss: nil)
        if shouldPublish {
            onPresented?(dialog)
        }
        return dialog
    }

    func attachDismissal(dialogID: String, dismissal: @escaping Dismissal) {
        guard var pending = resolutions[dialogID] else {
            dismissal()
            return
        }
        pending.dismiss = dismissal
        resolutions[dialogID] = pending
    }

    @discardableResult
    func respond(_ response: MobileBrowserDialogRespondParameters) -> Bool {
        let wasCurrent = queue.current?.dialogID == response.dialogID
        guard response.panelID == panelID,
              let dialog = queue.pending.first(where: { $0.dialogID == response.dialogID }),
              dialog.buttons.contains(where: { $0.id == response.buttonID }),
              queue.claim(dialogID: response.dialogID) != nil,
              let pending = resolutions.removeValue(forKey: response.dialogID) else {
            return false
        }
        pending.resolve(response.buttonID, response.text)
        pending.dismiss?()
        onResolved?(MobileBrowserDialogResolvedEvent(panelID: panelID, dialogID: response.dialogID))
        if wasCurrent, let next = queue.current {
            onPresented?(next)
        }
        return true
    }

    @discardableResult
    func resolveFromMac(dialogID: String, action: @escaping @MainActor () -> Void) -> Bool {
        let wasCurrent = queue.current?.dialogID == dialogID
        guard queue.claim(dialogID: dialogID) != nil,
              resolutions.removeValue(forKey: dialogID) != nil else {
            return false
        }
        action()
        onResolved?(MobileBrowserDialogResolvedEvent(panelID: panelID, dialogID: dialogID))
        if wasCurrent, let next = queue.current {
            onPresented?(next)
        }
        return true
    }

    func resolveAll() {
        let dialogs = queue.claimAll()
        for dialog in dialogs {
            guard let pending = resolutions.removeValue(forKey: dialog.dialogID) else { continue }
            let cancelButton = dialog.buttons.first(where: { $0.role == .cancel }) ?? dialog.buttons.first
            pending.resolve(cancelButton?.id ?? "cancel", nil)
            pending.dismiss?()
            onResolved?(MobileBrowserDialogResolvedEvent(panelID: panelID, dialogID: dialog.dialogID))
        }
    }
}
