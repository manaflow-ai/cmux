import CmuxFoundation
import SwiftUI

/// Native read-only ledger view; all validation and publication filtering live in the CLI.
struct ReviewPaneView: View {
    let directory: String?
    @State private var model: ReviewPaneModel
    @State private var selectedID = "latest"
    @State private var includeAll = false
    @State private var revision = 0

    init(directory: String?, cliPath: String, commands: any CommandRunning) {
        self.directory = directory
        _model = State(initialValue: ReviewPaneModel(commands: commands, cliPath: cliPath))
    }

    var body: some View {
        let runs = model.runs
        let findings = model.findings
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(String(localized: "review.pane.title", defaultValue: "Reviews"))
                    .font(.headline)
                Spacer()
                Button { revision += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .help(String(localized: "review.pane.refresh", defaultValue: "Refresh reviews"))
                    .accessibilityIdentifier("review.refresh")
                    .disabled(model.isLoading)
            }
            if directory == nil {
                Text(String(localized: "review.pane.localOnly", defaultValue: "Open a local Git repository to inspect its reviews."))
            } else if model.isLoading {
                ProgressView().frame(maxWidth: .infinity)
            } else if let error = model.error {
                Text(verbatim: error).foregroundStyle(.secondary).textSelection(.enabled)
            } else if model.runs.isEmpty {
                Text(String(localized: "review.pane.empty", defaultValue: "No reviews saved for this repository."))
                Text(String(localized: "review.pane.startHint", defaultValue: "Start a review in the terminal with cmux review run --intent <task>."))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            } else {
                Picker(String(localized: "review.pane.run", defaultValue: "Review"), selection: $selectedID) {
                    Text(String(localized: "review.pane.latest", defaultValue: "Latest")).tag("latest")
                    ForEach(runs) { run in
                        Text(verbatim: run.createdAt + " · " + String(run.id.prefix(8))).tag(run.id)
                    }
                }
                .accessibilityIdentifier("review.runPicker")
                Text(verbatim: model.intent).font(.subheadline).textSelection(.enabled)
                Text(String(localized: "review.pane.source", defaultValue: "Reviewed tree"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(verbatim: model.source).font(.caption.monospaced()).textSelection(.enabled)
                Text(String(localized: "review.pane.sourceHint", defaultValue: "This receipt applies to the recorded source snapshot. Later edits require a new review."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(String(localized: "review.pane.showAll", defaultValue: "Show refuted and suppressed findings"), isOn: $includeAll)
                    .toggleStyle(.checkbox).font(.caption)
                    .accessibilityIdentifier("review.showAll")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if findings.isEmpty {
                            Text(String(localized: "review.pane.noFindings", defaultValue: "No surfaced findings. This does not establish that the change is defect-free."))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(findings) { finding in
                            ReviewFindingRow(finding: finding)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .accessibilityIdentifier("review.pane")
        .task(id: request) {
            await model.load(directory: directory, selection: selectedID, includeAll: includeAll)
        }
        .onChange(of: model.isLoading) { _, loading in
            if !loading, selectedID != "latest", !model.runs.contains(where: { $0.id == selectedID }) {
                selectedID = "latest"
            }
        }
    }

    private var request: Request { Request(directory: directory, selectedID: selectedID, includeAll: includeAll, revision: revision) }

    private struct Request: Equatable {
        let directory: String?
        let selectedID: String
        let includeAll: Bool
        let revision: Int
    }
}
