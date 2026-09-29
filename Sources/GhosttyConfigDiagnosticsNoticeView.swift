import CmuxFoundation
import CmuxTerminalCore
import SwiftUI

/// Compact card listing the first Ghostty config errors, shown by
/// ``GhosttyConfigDiagnosticsNoticePresenter`` in the corner of a main window.
struct GhosttyConfigDiagnosticsNoticeView: View {
    let notice: GhosttyConfigDiagnosticsNotice
    let homeDirectory: String
    let openConfig: (() -> Void)?
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(String(
                    localized: "ghosttyConfigDiagnostics.notice.title",
                    defaultValue: "Ghostty config errors"
                ))
                .cmuxFont(.headline)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(notice.listedDiagnostics, id: \.message) { diagnostic in
                    Text(verbatim: abbreviated(diagnostic.message))
                        .cmuxFont(size: 11, design: .monospaced)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                if notice.unlistedCount > 0 {
                    Text(String(
                        localized: "ghosttyConfigDiagnostics.notice.more",
                        defaultValue: "More errors are not shown."
                    ))
                    .cmuxFont(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Text(String(
                localized: "ghosttyConfigDiagnostics.notice.hint",
                defaultValue: "Fix the file and save it; cmux reloads the config automatically."
            ))
            .cmuxFont(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(String(
                    localized: "ghosttyConfigDiagnostics.notice.dismiss",
                    defaultValue: "Dismiss"
                )) {
                    dismiss()
                }
                .controlSize(.small)
                if let openConfig {
                    Button(String(
                        localized: "ghosttyConfigDiagnostics.notice.open",
                        defaultValue: "Open Config"
                    )) {
                        openConfig()
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(12)
        .frame(width: 380, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("GhosttyConfigDiagnosticsNotice")
    }

    private func abbreviated(_ message: String) -> String {
        guard !homeDirectory.isEmpty, message.hasPrefix(homeDirectory + "/") else { return message }
        return "~" + message.dropFirst(homeDirectory.count)
    }
}
