public import AppKit
public import CmuxNextDesign

/// The person's approval of a socket call that only they may make (cmux issue 26412): a use of a
/// secret kept for them, and every store, delete or scope change. The socket cannot tell the
/// person's own `cmux` from an agent's: an agent can leave out its `caller`, run under a bundled
/// `cmux`, or type into the person's terminal. So the person answers on a native cmux sheet that
/// only they can press (the App's `debug.dialog` may not answer it; release builds have no
/// synthetic input), as `cmux settings set --confirm` does. Agent-scoped uses need no sheet.
extension CredentialVault {
    public static let approvalSheetIdentifier = "cmux.dialog.credentialVault.approve"
    public static let approvalAllowButton = "allow"

    /// What a socket call asks the person to allow.
    public nonisolated enum Approval: Equatable, Sendable {
        /// A command gets the values of `names`, some of them kept for the person.
        case use(names: [String], program: String?)
        case store(name: String, replaces: Bool)
        case remove(name: String)
        case scope(name: String, scope: [Consumer])
    }

    /// Shows the approval sheet and answers whether the person allowed it.
    public typealias Approve = @MainActor @Sendable (Approval) async -> Bool

    public static func approvalSheet(_ approval: Approval) -> CmuxDialogSpec {
        let title: String
        var lines: [String] = []
        var role = CmuxDialogButton.Role.default
        var allow = CredentialVaultStrings.approveAllow
        switch approval {
        case .use(let names, let program):
            title = CredentialVaultStrings.approveUseTitle(names.joined(separator: ", "))
            if let program, !program.isEmpty { lines.append(CredentialVaultStrings.approveProgram(program)) }
            lines.append(CredentialVaultStrings.approveUseLine)
        case .store(let name, let replaces):
            title = replaces ? CredentialVaultStrings.approveReplaceTitle(name) : CredentialVaultStrings.approveStoreTitle(name)
        case .remove(let name):
            title = CredentialVaultStrings.deleteTitle(name)
            lines.append(CredentialVaultStrings.deleteLine)
            role = .destructive
            allow = CredentialVaultStrings.deleteButton
        case .scope(let name, let scope):
            title = CredentialVaultStrings.approveScopeTitle(name)
            lines.append(CredentialVaultStrings.approveScopeLine(scope))
        }
        lines.append(CredentialVaultStrings.approveOnlyYou)
        return CmuxDialogSpec(title: title, lines: lines,
                              buttons: [.cancel(CredentialVaultStrings.entryCancel),
                                        CmuxDialogButton(id: approvalAllowButton, title: allow, role: role)],
                              identifier: approvalSheetIdentifier)
    }

    /// Asks on `window`; false when the person cancelled or closed it, or the asking task was
    /// cancelled (the request's connection closed or its deadline passed: the sheet goes).
    @MainActor
    public static func askApproval(_ approval: Approval, in window: NSWindow) async -> Bool {
        guard !Task.isCancelled else { return false }
        let shown = ShownApproval()
        let answer = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                shown.id = CmuxDialogCenter.shared.present(approvalSheet(approval), in: .window(window)) {
                    continuation.resume(returning: $0)
                }
            }
        } onCancel: {
            Task { @MainActor in if let id = shown.id { _ = CmuxDialogCenter.shared.dismiss(id) } }
        }
        return !Task.isCancelled && !answer.isDismissal && answer.button == approvalAllowButton
    }

    @MainActor private final class ShownApproval: Sendable {
        var id: Int?
    }
}
