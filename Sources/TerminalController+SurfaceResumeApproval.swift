import AppKit
import Foundation

/// Who proposed a resume binding. Only a person acting in the app may be asked
/// to approve one: a control-socket command that presents the modal parks the
/// command coordinator on the main actor and the socket stops answering (#13369).
enum SurfaceResumeProposalOrigin {
    case controlSocket
    case userInterface
}

extension SurfaceResumeApprovalStore {
    /// Whether a proposed binding needs a person's approval before it can
    /// auto-resume. Pure trust policy: it does not say whether a prompt can be
    /// shown, which depends on who proposed the binding.
    static func proposalNeedsApproval(
        binding: SurfaceResumeBindingSnapshot,
        existingRecord: SurfaceResumeApprovalRecord?
    ) -> Bool {
        guard binding.launchFlavor == .local else {
            return false
        }
        guard !binding.isCLIBinding else {
            return false
        }
        guard !binding.isProcessDetected, !binding.isAgentHookBinding else {
            return false
        }
        guard SurfaceResumeCommandCanonicalizer.isShellExpansionSafeCommand(binding.command) else {
            return false
        }
        guard let existingRecord else { return true }
        return existingRecord.policy == .prompt
    }
}

extension TerminalController {
    /// Applies stored approval to a proposed binding and, for a proposal made in
    /// the app, asks the user to approve it. A control-socket proposal that still
    /// needs approval is returned untrusted with `approvalRequired` set; it never
    /// presents UI.
    func surfaceResumeBindingWithApproval(
        _ binding: SurfaceResumeBindingSnapshot,
        origin: SurfaceResumeProposalOrigin
    ) -> SurfaceResumeApprovalLookup<(binding: SurfaceResumeBindingSnapshot, approvalRequired: Bool)> {
        let context: (
            effectiveBinding: SurfaceResumeBindingSnapshot,
            existingRecord: SurfaceResumeApprovalRecord?
        )
        switch SurfaceResumeApprovalStore.approvalProposalContext(for: binding) {
        case .pendingSigningSecret:
            return .pendingSigningSecret
        case let .resolved(resolvedContext):
            context = resolvedContext
        }
        var effectiveBinding = context.effectiveBinding
        if let promptlessCLIManualBinding = SurfaceResumeApprovalStore.applyingPromptlessCLIManualApprovalIfNeeded(
            to: binding,
            existingRecord: context.existingRecord
        ) {
            return .resolved((promptlessCLIManualBinding, false))
        }
        guard SurfaceResumeApprovalStore.proposalNeedsApproval(
            binding: binding,
            existingRecord: context.existingRecord
        ) else {
            return .resolved((effectiveBinding, false))
        }
        guard origin == .userInterface,
              SurfaceResumeApprovalStore.shouldPromptForProposal(
                  binding: binding,
                  existingRecord: context.existingRecord,
                  isMainThread: Thread.isMainThread,
                  isRunningTests: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
              ) else {
            return .resolved((effectiveBinding, true))
        }
        let approval = surfacePromptForResumeApproval(binding: effectiveBinding)
        guard let record = SurfaceResumeApprovalStore.approve(
            binding: binding,
            policy: approval.policy,
            commandPrefix: approval.commandPrefix
        ) else {
            return .resolved((effectiveBinding, true))
        }
        effectiveBinding.approvalPolicy = record.policy
        effectiveBinding.approvalRecordId = record.id
        effectiveBinding.autoResume = record.policy == .auto
        return .resolved((effectiveBinding, false))
    }

    var surfaceResumeApprovalPendingMessage: String {
        String(
            localized: "surfaceResumeApproval.pending.message",
            defaultValue: "Resume approval data is still loading. Retry the request."
        )
    }

    private func surfacePromptForResumeApproval(
        binding: SurfaceResumeBindingSnapshot
    ) -> (policy: SurfaceResumeApprovalPolicy, commandPrefix: [String]?) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(
            localized: "surfaceResumeApproval.proposal.title",
            defaultValue: "Allow Resume Command?"
        )
        let cwd = binding.cwd ?? String(localized: "surfaceResumeApproval.cwd.none", defaultValue: "None")
        let informativeText = String(
            format: String(
                localized: "surfaceResumeApproval.proposal.message",
                defaultValue: "A process wants cmux to keep this resume command for the current terminal:\n\nWorking directory: %@\n\n%@"
            ),
            cwd,
            binding.command
        )
        alert.addButton(withTitle: String(localized: "surfaceResumeApproval.proposal.auto", defaultValue: "Auto-Restore"))
        alert.addButton(withTitle: String(localized: "surfaceResumeApproval.proposal.ask", defaultValue: "Ask Each Time"))
        alert.addButton(withTitle: String(localized: "surfaceResumeApproval.proposal.manual", defaultValue: "Keep Manual"))
        let generalizedPrefix = SurfaceResumeCommandCanonicalizer.generalizedApprovalPrefix(
            forCommand: binding.command
        )
        let folderScopedGeneralizedPrefix =
            SurfaceResumeCommandCanonicalizer.normalizedCWD(binding.cwd) == nil
            ? nil
            : generalizedPrefix
        if let generalizedPrefix = folderScopedGeneralizedPrefix {
            let renderedPrefix = generalizedPrefix
                .map(SurfaceResumeCommandCanonicalizer.shellQuoted)
                .joined(separator: " ")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = String(
                format: String(
                    localized: "surfaceResumeApproval.proposal.applyToPrefix",
                    defaultValue: "Apply to all commands starting with “%@” in this folder"
                ),
                renderedPrefix
            )
        }
        let content = CmuxAlertContent(
            flattenedText: informativeText,
            separatingScrollableDetails: binding.command
        )
        content.apply(to: alert, presentingWindow: nil)

        let response = alert.runModal()
        let commandPrefix = alert.suppressionButton?.state == .on
            ? folderScopedGeneralizedPrefix
            : nil
        return switch response {
        case .alertFirstButtonReturn: (.auto, commandPrefix)
        case .alertSecondButtonReturn: (.prompt, commandPrefix)
        default: (.manual, commandPrefix)
        }
    }
}
