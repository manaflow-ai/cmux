import AppKit
import Foundation

/// One resume-command proposal awaiting the user's "Allow Resume Command?"
/// decision.
///
/// The binding is already stored on the surface without auto-resume trust
/// when the proposal is queued; `apply` upgrades it once the user decides.
struct SurfaceResumeApprovalProposal {
    /// The binding exactly as it was stored on the surface.
    let binding: SurfaceResumeBindingSnapshot
    /// The window that owns the surface, preferred as the sheet host.
    weak var preferredWindow: NSWindow?
    /// Applies the user's signed decision to the live surface binding.
    let apply: @MainActor (SurfaceResumeApprovalRecord) -> Void
}

/// How the prompter shows one approval alert.
///
/// The production presenter attaches a window sheet. Tests substitute a
/// recorder so the queue, dedupe, and decision plumbing run without AppKit
/// windows.
@MainActor
protocol SurfaceResumeApprovalSheetPresenting: AnyObject {
    /// Presents `alert`, preferring `window` as the host, and reports the
    /// user's response; reports `nil` when no window can host the sheet.
    func presentApprovalAlert(
        _ alert: NSAlert,
        preferring window: NSWindow?,
        completion: @escaping @MainActor (NSApplication.ModalResponse?) -> Void
    )
}

/// The AppKit presenter: a sheet on a visible cmux main window.
///
/// Never `runModal()`. A nested modal run loop started from a main-actor job
/// does not drain the main dispatch queue, so every other main-actor job in
/// the process (every control-socket command, the hang watchdog heartbeat)
/// starves until the alert closes. That is how one `surface.resume.set`
/// wedged the whole control socket in
/// <https://github.com/manaflow-ai/cmux/issues/13369>.
@MainActor
final class SurfaceResumeApprovalSheetPresenter: SurfaceResumeApprovalSheetPresenting {
    func presentApprovalAlert(
        _ alert: NSAlert,
        preferring window: NSWindow?,
        completion: @escaping @MainActor (NSApplication.ModalResponse?) -> Void
    ) {
        guard let host = NSApp.cmuxMainWindowForModalPresentation(preferring: window) else {
            completion(nil)
            return
        }
        alert.beginSheetModal(for: host) { response in
            completion(response)
        }
    }
}

/// What the prompter should do with a queued proposal when its turn comes.
enum SurfaceResumeApprovalPromptResolution {
    /// No record answers this command yet (or the record asks each time):
    /// present the sheet.
    case prompt
    /// A record written since the proposal was queued (an earlier answer in
    /// this queue, or Settings) already decides it: apply that record to the
    /// proposal's binding without asking again.
    case covered(SurfaceResumeApprovalRecord)
    /// The approval store cannot answer right now (signing secret still
    /// loading); the binding stays manual.
    case unavailable
}

/// The single owner of resume-command approval prompting.
///
/// Every proposal, whether it arrived over the control socket or from the
/// terminal context menu, is stored first and asked about later: the prompter
/// presents one sheet at a time, in arrival order, and re-checks whether a
/// prompt is still needed before showing it so one decision covers every
/// identical proposal queued behind it. No command path ever waits on the
/// user.
@MainActor
final class SurfaceResumeApprovalPrompter {
    /// Decides, when a proposal's turn comes, whether it still needs the user,
    /// is already covered by a record, or cannot be answered.
    typealias Resolve = @MainActor (SurfaceResumeBindingSnapshot) -> SurfaceResumeApprovalPromptResolution
    /// Writes the signed approval record for a decision.
    typealias Approve = @MainActor (
        _ binding: SurfaceResumeBindingSnapshot,
        _ policy: SurfaceResumeApprovalPolicy,
        _ commandPrefix: [String]?
    ) -> SurfaceResumeApprovalRecord?

    private let presenter: any SurfaceResumeApprovalSheetPresenting
    private let canPrompt: Bool
    private let resolve: Resolve
    private let approve: Approve
    private var queue: [SurfaceResumeApprovalProposal] = []
    private var isPresenting = false
    /// Alerts the user has answered since launch.
    private(set) var decidedCount = 0
    /// Proposals dropped because no window could host the sheet.
    private(set) var unpresentableCount = 0

    /// Creates the prompter.
    ///
    /// - Parameters:
    ///   - presenter: The sheet presenter.
    ///   - canPrompt: Whether this process may show approval UI at all. The
    ///     app passes `false` when hosted by a unit-test runner.
    ///   - resolve: The re-check run before each presentation.
    ///   - approve: The record writer.
    init(
        presenter: any SurfaceResumeApprovalSheetPresenting,
        canPrompt: Bool,
        resolve: @escaping Resolve = { binding in
            SurfaceResumeApprovalStore.promptResolution(for: binding)
        },
        approve: @escaping Approve = { binding, policy, commandPrefix in
            SurfaceResumeApprovalStore.approve(
                binding: binding,
                policy: policy,
                commandPrefix: commandPrefix
            )
        }
    ) {
        self.presenter = presenter
        self.canPrompt = canPrompt
        self.resolve = resolve
        self.approve = approve
    }

    /// Proposals waiting for or currently showing a sheet.
    var pendingProposalCount: Int {
        queue.count + (isPresenting ? 1 : 0)
    }

    /// Queues a proposal and presents it when its turn comes.
    ///
    /// - Returns: `false` when this process cannot show approval UI, so the
    ///   caller reports the binding as stored without a pending decision.
    @discardableResult
    func enqueue(_ proposal: SurfaceResumeApprovalProposal) -> Bool {
        guard canPrompt else { return false }
        queue.append(proposal)
        presentNextIfNeeded()
        return true
    }

    private func presentNextIfNeeded() {
        guard !isPresenting else { return }
        while !queue.isEmpty {
            let proposal = queue.removeFirst()
            // An earlier answer, or a record written through Settings, may
            // already cover this command: never ask the same question twice,
            // but do apply that decision to every surface it covers.
            switch resolve(proposal.binding) {
            case .covered(let record):
                proposal.apply(record)
                continue
            case .unavailable:
                continue
            case .prompt:
                break
            }
            isPresenting = true
            let alert = Self.makeAlert(for: proposal.binding)
            presenter.presentApprovalAlert(alert.alert, preferring: proposal.preferredWindow) { [weak self] response in
                guard let self else { return }
                self.isPresenting = false
                if let response {
                    self.decidedCount += 1
                    let decision = Self.decision(
                        for: response,
                        suppressionOn: alert.alert.suppressionButton?.state == .on,
                        folderScopedPrefix: alert.folderScopedPrefix
                    )
                    if let record = self.approve(proposal.binding, decision.policy, decision.commandPrefix) {
                        proposal.apply(record)
                    }
                } else {
                    // Nothing can host a sheet (no visible main window). The
                    // binding stays manual and safe; editing the command from
                    // the terminal context menu proposes it again.
                    self.unpresentableCount += 1
                }
                self.presentNextIfNeeded()
            }
            return
        }
    }

    static func decision(
        for response: NSApplication.ModalResponse,
        suppressionOn: Bool,
        folderScopedPrefix: [String]?
    ) -> (policy: SurfaceResumeApprovalPolicy, commandPrefix: [String]?) {
        let commandPrefix = suppressionOn ? folderScopedPrefix : nil
        return switch response {
        case .alertFirstButtonReturn: (.auto, commandPrefix)
        case .alertSecondButtonReturn: (.prompt, commandPrefix)
        default: (.manual, commandPrefix)
        }
    }

    /// Builds the "Allow Resume Command?" alert for `binding`.
    static func makeAlert(
        for binding: SurfaceResumeBindingSnapshot
    ) -> (alert: NSAlert, folderScopedPrefix: [String]?) {
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
        return (alert, folderScopedGeneralizedPrefix)
    }
}

extension SurfaceResumeApprovalStore {
    /// How a queued proposal should be handled when its turn comes: prompt
    /// when no record answers the command yet (or the record asks each time),
    /// apply the covering record otherwise, and wait when the store is still
    /// loading.
    static func promptResolution(
        for binding: SurfaceResumeBindingSnapshot
    ) -> SurfaceResumeApprovalPromptResolution {
        switch approvalProposalContext(for: binding) {
        case .pendingSigningSecret:
            return .unavailable
        case let .resolved(context):
            if shouldPromptForProposal(binding: binding, existingRecord: context.existingRecord) {
                return .prompt
            }
            guard let record = context.existingRecord else { return .unavailable }
            return .covered(record)
        }
    }
}
