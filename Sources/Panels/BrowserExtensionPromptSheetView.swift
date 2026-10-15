import AppKit
import CmuxBrowser
import SwiftUI

/// The body of a cmux extension sheet (design spec §3a).
///
/// Icon and question, who asked (automation only), the exact target in a
/// monospaced well, what the extension can do, then a quiet note and the
/// buttons. Cancel is the default (Return and Escape); the grant is a plain,
/// non-default button so it is never pressed by accident.
/// Refs: cmux-design-references `apps/codex/web/computer-use-app-approval.webp`,
/// `apps/claude/web/cli-command-approval.png`, `apps/claude/web/workspace-trust.png`.
struct BrowserExtensionPromptSheetView: View {
    let content: BrowserExtensionPromptContent
    let icon: NSImage?
    let onAnswer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                iconView
                Text(content.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            if let requester = content.requester {
                Text(requester)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(content.target)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
            permissionList
            if let note = content.note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(content.acceptTitle) { onAnswer(true) }
                    .accessibilityIdentifier("browser.extension.prompt.accept")
                Button(content.cancelTitle) { onAnswer(false) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("browser.extension.prompt.cancel")
            }
            .controlSize(.regular)
        }
        .padding(20)
        .frame(width: 400)
    }

    @ViewBuilder private var iconView: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var permissionList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(content.permissionsHeading)
                .font(.callout)
            ForEach(Array(content.permissions.enumerated()), id: \.offset) { _, permission in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: "\u{2022}").foregroundStyle(.secondary)
                        Text(permission.message).font(.callout)
                    }
                    if !permission.details.isEmpty {
                        Text(permission.details)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(6)
                            .padding(.leading, 14)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
