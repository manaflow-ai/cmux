#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// Root screen for loading and browsing a workspace's changed files.
struct MobileDiffTreeScreen: View {
    let model: MobileDiffViewerModel
    let selectFile: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if model.snapshot == nil, model.errorMessage == nil {
                ProgressView(
                    L10n.string("mobile.diff.loadingChanges", defaultValue: "Loading changes…")
                )
            } else if let errorMessage = model.errorMessage {
                errorState(errorMessage)
            } else if let snapshot = model.snapshot, snapshot.files.isEmpty {
                ContentUnavailableView(
                    L10n.string("mobile.diff.noChanges", defaultValue: "No changes"),
                    systemImage: "checkmark.circle"
                )
            } else if let snapshot = model.snapshot {
                MobileDiffTreeView(
                    snapshot: snapshot,
                    collapsedDirectories: model.collapsedDirectories,
                    tooLargePaths: model.tooLargePaths,
                    selectedPath: nil,
                    toggleDirectory: model.toggleDirectory,
                    selectFile: selectFile
                )
                .refreshable { await model.load() }
            }
        }
        .navigationTitle(L10n.string("mobile.diff.changes", defaultValue: "Changes"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel(L10n.string("mobile.diff.close", defaultValue: "Close"))
            }
        }
    }

    private func errorState(_ message: String) -> some View {
        ContentUnavailableView {
            Label(
                L10n.string("mobile.diff.unavailable", defaultValue: "Changes unavailable"),
                systemImage: "exclamationmark.triangle"
            )
        } description: {
            Text(message)
        } actions: {
            Button(L10n.string("mobile.diff.retry", defaultValue: "Retry")) {
                Task { await model.load() }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
#endif
