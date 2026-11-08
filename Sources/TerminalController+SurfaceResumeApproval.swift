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
    /// Eligibility is independent of an existing decision. An explicit UI review
    /// may change Manual/Ask to Auto, but must never promote an imported or
    /// otherwise non-reviewable binding.
    static func proposalAllowsUserApproval(binding: SurfaceResumeBindingSnapshot) -> Bool {
        binding.launchFlavor == .local &&
            !binding.isCLIBinding && !binding.isUntrustedSessionImportBinding &&
            !binding.isProcessDetected && !binding.isAgentHookBinding &&
            SurfaceResumeCommandCanonicalizer.isShellExpansionSafeCommand(binding.command)
    }

    /// The explicit review signs every stored field, so it is limited to what
    /// the prompt can show. A captured launch command is not displayed.
    static func proposalAllowsExplicitReview(binding: SurfaceResumeBindingSnapshot) -> Bool {
        proposalAllowsUserApproval(binding: binding) && binding.launchCommand == nil
    }

    /// The command plus any environment the approval record signs, so a
    /// proposal cannot hide a variable such as `ZDOTDIR` behind its command.
    static func approvalPromptDetails(
        binding: SurfaceResumeBindingSnapshot,
        environmentLabel: String
    ) -> String {
        guard let environment = binding.environment, !environment.isEmpty else {
            return binding.command
        }
        let assignments = environment.keys.sorted().map { key in
            "\(key)=\(SurfaceResumeCommandCanonicalizer.shellQuoted(environment[key] ?? ""))"
        }
        return ([binding.command, "", environmentLabel] + assignments).joined(separator: "\n")
    }

    /// Whether a proposed binding needs a person's approval before it can
    /// auto-resume. Pure trust policy: it does not say whether a prompt can be
    /// shown, which depends on who proposed the binding.
    static func proposalNeedsApproval(
        binding: SurfaceResumeBindingSnapshot,
        existingRecord: SurfaceResumeApprovalRecord?
    ) -> Bool {
        guard proposalAllowsUserApproval(binding: binding) else {
            return false
        }
        guard let existingRecord else { return true }
        return existingRecord.policy == .prompt
    }
}

extension TerminalController {
    /// Called only by the terminal's explicit Review Approval action, never by
    /// the socket coordinator. Review the stored value rather than rebuilding
    /// it from the command editor (which intentionally creates a manual binding).
    /// The native modal runs a nested event loop: revalidate before signing.
    func surfaceResumeBindingByReviewingApproval(
        _ binding: SurfaceResumeBindingSnapshot,
        proposalIsCurrent: () -> Bool
    ) -> SurfaceResumeApprovalLookup<(binding: SurfaceResumeBindingSnapshot, approvalRequired: Bool)> {
        guard SurfaceResumeApprovalStore.proposalAllowsExplicitReview(binding: binding),
              proposalIsCurrent() else {
            return .resolved((binding, true))
        }
        switch SurfaceResumeApprovalStore.approvalProposalContext(for: binding) {
        case .pendingSigningSecret:
            return .pendingSigningSecret
        case .resolved:
            break
        }
        guard Thread.isMainThread,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              proposalIsCurrent() else {
            return .resolved((binding, true))
        }
        let approval = surfacePromptForResumeApproval(binding: binding)
        guard proposalIsCurrent(),
              let record = SurfaceResumeApprovalStore.approve(
                  binding: binding,
                  policy: approval.policy,
                  commandPrefix: approval.commandPrefix
              ) else {
            return .resolved((binding, true))
        }
        var reviewed = binding
        reviewed.approvalPolicy = record.policy
        reviewed.approvalRecordId = record.id
        reviewed.autoResume = record.policy == .auto
        return .resolved((reviewed, false))
    }

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
        let details = SurfaceResumeApprovalStore.approvalPromptDetails(
            binding: binding,
            environmentLabel: String(
                localized: "surfaceResumeApproval.environment.label",
                defaultValue: "Environment:"
            )
        )
        let informativeText = String(
            format: String(
                localized: "surfaceResumeApproval.proposal.message",
                defaultValue: "A process wants cmux to keep this resume command for the current terminal:\n\nWorking directory: %@\n\n%@"
            ),
            cwd,
            details
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
            separatingScrollableDetails: details
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
