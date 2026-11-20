public import CMUXMobileCore
import Foundation

/// Owns panel-wide native browser dialog completions and arbitrates Mac/phone answers.
@MainActor
public final class MobileBrowserDialogBroker {
    public typealias Resolver = @MainActor (_ buttonID: String, _ text: String?) -> Void
    public typealias Dismissal = @MainActor () -> Void

    private struct PendingResolution {
        let resolve: Resolver
        var dismiss: Dismissal?
    }

    public let panelID: String
    public var onPresented: (@MainActor (MobileBrowserDialogEvent) -> Void)?
    public var onResolved: (@MainActor (MobileBrowserDialogResolvedEvent) -> Void)?

    private var queue = MobileBrowserDialogQueue()
    private var resolutions: [String: PendingResolution] = [:]

    public init(panelID: String) {
        self.panelID = panelID
    }

    public var currentDialog: MobileBrowserDialogEvent? { queue.current }

    /// Every unresolved dialog, including dialogs whose native presentation is deferred.
    public var pendingDialogs: [MobileBrowserDialogEvent] { queue.pending }

    @discardableResult
    public func begin(
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

    public func attachDismissal(dialogID: String, dismissal: @escaping Dismissal) {
        guard var pending = resolutions[dialogID] else {
            dismissal()
            return
        }
        pending.dismiss = dismissal
        resolutions[dialogID] = pending
    }

    @discardableResult
    public func respond(_ response: MobileBrowserDialogRespondParameters) -> Bool {
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
    public func resolveFromMac(dialogID: String, action: @escaping @MainActor () -> Void) -> Bool {
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

    /// Cancels a batch atomically, preserving unrelated dialogs and FIFO completion order.
    /// - Parameter predicate: Selects dialogs to cancel; defaults to all dialogs for teardown.
    public func resolveAll(where predicate: (MobileBrowserDialogEvent) -> Bool = { _ in true }) {
        let previousID = queue.current?.dialogID
        let dialogs = queue.claimAll(where: predicate)
        let next = queue.current
        let claimed = dialogs.compactMap { dialog -> (MobileBrowserDialogEvent, PendingResolution)? in
            guard let pending = resolutions.removeValue(forKey: dialog.dialogID) else { return nil }
            return (dialog, pending)
        }
        for (dialog, pending) in claimed {
            let cancelButton = dialog.buttons.first(where: { $0.role == .cancel }) ?? dialog.buttons.first
            pending.resolve(cancelButton?.id ?? "cancel", nil)
            pending.dismiss?()
            onResolved?(MobileBrowserDialogResolvedEvent(panelID: panelID, dialogID: dialog.dialogID))
        }
        if previousID != next?.dialogID, let next, queue.current?.dialogID == next.dialogID {
            onPresented?(next)
        }
    }
}
