import CmuxNextDesign
import SwiftUI

/// The MCP audit log sheet: the newest lines, oldest first, as acpmux recorded them (digests only).
struct McpAuditLogView: View {
    let lines: [String]
    let close: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(McpServersStrings.auditTitle).font(.headline)
            Text(McpServersStrings.auditNote).font(.caption).foregroundStyle(.secondary)
            if lines.isEmpty {
                Text(McpServersStrings.auditEmpty).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                CmuxDialogActionButton(McpServersStrings.done, hint: .return) { close() }
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 360)
    }
}
