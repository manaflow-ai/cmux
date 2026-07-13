#if canImport(UIKit) && DEBUG
import CmuxMobileShell
import SwiftUI

struct DeleteComputersVerifierView: View {
    @State private var result: MobileDeleteComputersVerificationResult?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(statusText)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(result?.passed == true ? .green : .orange)
                        .accessibilityIdentifier("DeleteComputersVerifierStatus")

                    if let result {
                        Text(verbatim: result.reason)
                            .font(.system(.body, design: .monospaced))
                            .accessibilityIdentifier("DeleteComputersVerifierReason")

                        Text(String(
                            localized: "mobile.deleteComputersVerifier.halfRemovedAbsent",
                            defaultValue: "halfRemovedAbsent="
                        ) + "\(result.halfRemovedAbsent)")
                        Text(String(
                            localized: "mobile.deleteComputersVerifier.halfRemainingPresent",
                            defaultValue: "halfRemainingPresent="
                        ) + "\(result.halfRemainingPresent)")
                        Text(String(
                            localized: "mobile.deleteComputersVerifier.halfNoDisconnectedBanner",
                            defaultValue: "halfNoDisconnectedBanner="
                        ) + "\(result.halfNoDisconnectedBanner)")
                        Text(String(
                            localized: "mobile.deleteComputersVerifier.refreshPreservedHalfList",
                            defaultValue: "refreshPreservedHalfList="
                        ) + "\(result.refreshPreservedHalfList)")
                        Text(String(
                            localized: "mobile.deleteComputersVerifier.allRemoved",
                            defaultValue: "allRemoved="
                        ) + "\(result.allRemoved)")
                        Text(String(
                            localized: "mobile.deleteComputersVerifier.refreshPreservedEmptyList",
                            defaultValue: "refreshPreservedEmptyList="
                        ) + "\(result.refreshPreservedEmptyList)")

                        if let evidencePath = result.evidencePath {
                            Text(verbatim: evidencePath)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }

                        ForEach(result.checkpoints, id: \.name) { checkpoint in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(checkpointSummaryText(checkpoint))
                                    .font(.headline)
                                Text(computersText(checkpoint.displayMacIDs))
                                    .font(.system(.caption, design: .monospaced))
                                ForEach(Array(checkpoint.pages.enumerated()), id: \.offset) { pageIndex, page in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(pageText(pageIndex + 1))
                                            .font(.caption.weight(.semibold))
                                        ForEach(page, id: \.id) { workspace in
                                            Text(verbatim: "\(workspace.id) [\(workspace.macDeviceID ?? "nil")]")
                                                .font(.system(.caption, design: .monospaced))
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                            .padding(.vertical, 8)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle(Text(String(
                localized: "mobile.deleteComputersVerifier.title",
                defaultValue: "Delete Computers Verifier"
            )))
        }
        .task {
            result = await MobileDeleteComputersVerifier().runAndPersist()
        }
    }

    private var statusText: String {
        if result?.passed == true {
            return String(localized: "mobile.deleteComputersVerifier.status.pass", defaultValue: "PASS")
        }
        return String(localized: "mobile.deleteComputersVerifier.status.running", defaultValue: "RUNNING")
    }

    private func checkpointSummaryText(_ checkpoint: MobileDeleteComputersVerificationCheckpoint) -> String {
        let countLabel = String(
            localized: "mobile.deleteComputersVerifier.checkpoint.workspacesStatus",
            defaultValue: " workspaces, status "
        )
        return "\(checkpoint.name): \(checkpoint.workspaceCount)" + countLabel + checkpoint.workspaceListStatus
    }

    private func computersText(_ macIDs: [String]) -> String {
        String(
            localized: "mobile.deleteComputersVerifier.checkpoint.computers",
            defaultValue: "computers: "
        ) + macIDs.joined(separator: ", ")
    }

    private func pageText(_ page: Int) -> String {
        String(localized: "mobile.deleteComputersVerifier.checkpoint.page", defaultValue: "page ") + "\(page)"
    }
}
#endif
