import AppKit
import CmuxNextCloud
import CmuxNextCloudUI
import CmuxNextCompat
import CmuxNextDesign

/// Presents the reusable card in the standard dialog; cancellation dismisses its owned dialog.
@MainActor
final class CloudGitHubConnectorPresentation {
    private var dialogID: Int?
    private let center: CmuxDialogCenter
    private let client: any CloudGitHubConnectorClient
    private let isCurrent: @MainActor () -> Bool

    init(client: any CloudGitHubConnectorClient, center: CmuxDialogCenter,
         isCurrent: @escaping @MainActor () -> Bool) {
        self.client = client
        self.center = center
        self.isCurrent = isCurrent
    }

    func present(_ spec: CmuxDialogSpec, in scope: CmuxDialogScope, retryOnReturn: Bool = false) async -> CmuxDialogAnswer {
        let model = CloudGitHubConnectorModel(client: client, openInstallURL: { [weak self] url in
            guard let self, self.isCurrent() else { throw CancellationError() }
            let opened = await withCheckedContinuation { continuation in
                NSWorkspace.shared.openInBackground(url) { continuation.resume(returning: $0) }
            }
            guard opened else { throw CloudGitHubConnectorClientError.requestFailed }
        }, retryRepository: { [weak self] in
            guard retryOnReturn, let self, self.isCurrent(), let id = self.dialogID else { return }
            self.center.press(id, button: "retry")
        }, scopeIsCurrent: { [weak self] in self?.isCurrent() ?? false })
        let card = CloudGitHubConnectorCard(model: model)
        card.onSelectRepository = { [weak self] repo in
            guard let self, self.isCurrent(), let id = self.dialogID else { return }
            self.center.setValue(.text(repo.spec), for: "repository", in: id)
            if self.center.record(id)?.values["source"]?.text != "newEnvironment" {
                self.center.setValue(.text("repository"), for: "source", in: id)
            }
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, isCurrent() else {
                    continuation.resume(returning: CmuxDialogAnswer(button: "cancel", role: .cancel, isDismissal: true))
                    return
                }
                dialogID = center.present(spec, in: scope, accessory: card.accessory) { [weak self] answer in
                    self?.dialogID = nil
                    continuation.resume(returning: answer)
                }
            }
        } onCancel: { [weak self] in
            // task-owner: one cancellation delivery; dismissing ends the card's network work and observers.
            Task { @MainActor in
                if let self, let id = self.dialogID { self.center.dismiss(id) }
            }
        }
    }

    /// This is also Auto's recovery seam: it accepts an existing machine and repository, never a create closure.
    func recover(_ completion: CloudMachineBootstrap.Completion, repo: CloudMachineRepo,
                 on machine: CloudMachineBootstrap.Machine, in scope: CmuxDialogScope) async throws -> CloudMachineBootstrap.Completion {
        var result = completion
        while case .repositoryFailed(let reason) = result {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            let spec = CloudGitHubConnectorCard.recoveryDialog(reason: reason)
            let answer = await present(spec, in: scope, retryOnReturn: true)
            try Task.checkCancellation()
            guard isCurrent(), answer.button == "retry", !answer.isDismissal else { throw CancellationError() }
            // Only the existing machine's repo step. No creation/session retry or credential transfer.
            result = CloudMachineBootstrap.completion(await repo.retry(on: machine))
            guard isCurrent() else { throw CancellationError() }
        }
        return result
    }
}
