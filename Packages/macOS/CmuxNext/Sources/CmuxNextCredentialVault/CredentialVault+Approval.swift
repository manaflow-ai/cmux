public import AppKit
public import CmuxNextDesign
import Foundation

/// The person's approval of a socket call that only they may make (cmux issue 26412): a use of a
/// secret kept for them, and every store, delete or scope change. The socket cannot tell the
/// person's own `cmux` from an agent's: an agent can leave out its `caller`, run under a bundled
/// `cmux`, or type into the person's terminal. So the person answers on a native cmux sheet that
/// only they can press (while it is open the App's `debug.dialog` may not answer it and its synthetic
/// mouse and key verbs refuse to run; release builds have none of them), as `cmux settings set
/// --confirm` does. Agent-scoped uses need no sheet.
///
/// Allow takes only a pointer click, none in its first half second on screen and none that only
/// brings its window forward: no key presses
/// it and it never has the keyboard (Cancel does), so typing meant for a terminal or the composer
/// when the sheet appears, or a click aimed at what was there, never approves. Every text on
/// it is the vault's own or a vault name; the program a caller names is reduced to a name.
extension CredentialVault {
    public static let approvalSheetIdentifier = "cmux.dialog.credentialVault.approve"
    public static let approvalAllowButton = "allow"

    /// What a socket call asks the person to allow.
    public nonisolated enum Approval: Equatable, Sendable {
        /// A command gets the values of `names`, some of them kept for the person.
        /// `program`: what the caller says it will run (``displayProgram(_:)``), not checked.
        case use(names: [String], program: String?)
        /// A value the asking program supplies; `scope`: who may use it once stored (a replaced
        /// one's when the call names none, every consumer for a new one), always shown.
        case store(name: String, replaces: Bool, scope: [Consumer])
        case remove(name: String)
        case scope(name: String, scope: [Consumer])
    }

    /// Shows the approval sheet and answers whether the person allowed it.
    public typealias Approve = @MainActor @Sendable (Approval) async -> Bool

    public static func approvalSheet(_ approval: Approval) -> CmuxDialogSpec {
        let title: String
        var lines: [String] = []
        var role = CmuxDialogButton.Role.normal
        var allow = CredentialVaultStrings.approveAllow
        switch approval {
        case .use(let names, let program):
            title = CredentialVaultStrings.approveUseTitle(names.joined(separator: ", "))
            if let program, !program.isEmpty { lines.append(CredentialVaultStrings.approveProgram(program)) }
            lines.append(CredentialVaultStrings.approveUseLine)
        case .store(let name, let replaces, let scope):
            title = replaces ? CredentialVaultStrings.approveReplaceTitle(name) : CredentialVaultStrings.approveStoreTitle(name)
            lines.append(CredentialVaultStrings.approveStoreLine)
            lines.append(CredentialVaultStrings.approveScopeLine(scope))
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
                                        CmuxDialogButton(id: approvalAllowButton, title: allow, role: role, clickOnly: true)],
                              identifier: approvalSheetIdentifier)
    }

    /// A program name as an approval sheet shows it: ASCII letters, digits and `-_.+@`, at most 40,
    /// so a caller cannot put words, spacing or direction marks on the sheet.
    nonisolated static func displayProgram(_ raw: String) -> String? {
        let kept = commandSummary(raw).unicodeScalars.filter {
            ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || "-_.+@".unicodeScalars.contains($0)
        }
        let text = String(String.UnicodeScalarView(kept.prefix(40)))
        return text.isEmpty ? nil : text
    }

    /// A caller's reason as the entry sheet shows it (and the note keeps it): one line, no control,
    /// format (direction marks, zero-width) or private-use characters, spaces collapsed, at most
    /// ``maxNoteCharacters``; nil when nothing is left.
    nonisolated static func oneLine(_ raw: String) -> String? {
        var text = ""
        var space = false
        for scalar in raw.unicodeScalars {
            if scalar.properties.isWhitespace {
                space = !text.isEmpty
                continue
            }
            switch scalar.properties.generalCategory {
            case .control, .format, .privateUse, .surrogate, .unassigned, .lineSeparator, .paragraphSeparator: continue
            default: break
            }
            if space { text.append(" ") }
            space = false
            text.unicodeScalars.append(scalar)
        }
        let line = String(text.prefix(maxNoteCharacters))
        return line.isEmpty ? nil : line
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
