#if canImport(UIKit) && DEBUG
import CmuxMobileShell
import SwiftUI

struct DeleteComputersVerifierView: View {
    @State private var result: MobileDeleteComputersVerificationResult?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: result?.passed == true ? "PASS" : "RUNNING")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(result?.passed == true ? .green : .orange)
                        .accessibilityIdentifier("DeleteComputersVerifierStatus")

                    if let result {
                        Text(verbatim: result.reason)
                            .font(.system(.body, design: .monospaced))
                            .accessibilityIdentifier("DeleteComputersVerifierReason")

                        Text(verbatim: "halfRemovedAbsent=\(result.halfRemovedAbsent)")
                        Text(verbatim: "halfRemainingPresent=\(result.halfRemainingPresent)")
                        Text(verbatim: "halfNoDisconnectedBanner=\(result.halfNoDisconnectedBanner)")
                        Text(verbatim: "refreshPreservedHalfList=\(result.refreshPreservedHalfList)")
                        Text(verbatim: "allRemoved=\(result.allRemoved)")
                        Text(verbatim: "refreshPreservedEmptyList=\(result.refreshPreservedEmptyList)")

                        if let evidencePath = result.evidencePath {
                            Text(verbatim: evidencePath)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }

                        ForEach(result.checkpoints, id: \.name) { checkpoint in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(verbatim: "\(checkpoint.name): \(checkpoint.workspaceCount) workspaces, status \(checkpoint.workspaceListStatus)")
                                    .font(.headline)
                                Text(verbatim: "computers: \(checkpoint.displayMacIDs.joined(separator: ", "))")
                                    .font(.system(.caption, design: .monospaced))
                                ForEach(Array(checkpoint.pages.enumerated()), id: \.offset) { pageIndex, page in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(verbatim: "page \(pageIndex + 1)")
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
            .navigationTitle(Text(verbatim: "Delete Computers Verifier"))
        }
        .task {
            result = await MobileDeleteComputersVerifier.runAndPersist()
        }
    }
}
#endif
