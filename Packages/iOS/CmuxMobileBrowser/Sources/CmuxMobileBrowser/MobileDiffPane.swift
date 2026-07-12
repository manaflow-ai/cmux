#if canImport(UIKit)
public import SwiftUI
import CmuxMobileSupport
import Foundation

/// Native iOS chrome around the shared web diff renderer.
public struct MobileDiffPane: View {
    @State private var state: MobileDiffState
    @State private var showsFiles = false
    private let onClose: () -> Void
    private let onReload: () -> Void

    public init(
        state: MobileDiffState,
        onClose: @escaping () -> Void,
        onReload: @escaping () -> Void
    ) {
        _state = State(initialValue: state)
        self.onClose = onClose
        self.onReload = onReload
    }

    public var body: some View {
        VStack(spacing: 0) {
            MobileDiffNavigationBar(
                selectedFile: state.selectedFile,
                fileCount: state.files.count,
                canSelectPrevious: state.canSelectPrevious,
                canSelectNext: state.canSelectNext,
                showFiles: { showsFiles = true },
                selectPrevious: state.selectPrevious,
                selectNext: state.selectNext,
                reload: onReload,
                close: onClose
            )
            Divider()
            MobileDiffContent(state: state, reload: onReload)
        }
        .background(Color(.systemBackground))
        .sheet(isPresented: $showsFiles) {
            MobileDiffFileList(state: state, dismiss: { showsFiles = false })
        }
    }
}

private struct MobileDiffNavigationBar: View {
    let selectedFile: MobileDiffFile?
    let fileCount: Int
    let canSelectPrevious: Bool
    let canSelectNext: Bool
    let showFiles: () -> Void
    let selectPrevious: () -> Void
    let selectNext: () -> Void
    let reload: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: showFiles) {
                HStack(spacing: 7) {
                    Image(systemName: "list.bullet")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(selectedFile?.name ?? L10n.string("mobile.diff.files", defaultValue: "Changed Files"))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(fileCountLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("MobileDiffFileListButton")

            Button(action: selectPrevious) { Image(systemName: "chevron.up") }
                .disabled(!canSelectPrevious)
                .accessibilityLabel(L10n.string("mobile.diff.previousFile", defaultValue: "Previous File"))
            Button(action: selectNext) { Image(systemName: "chevron.down") }
                .disabled(!canSelectNext)
                .accessibilityLabel(L10n.string("mobile.diff.nextFile", defaultValue: "Next File"))
            Button(action: reload) { Image(systemName: "arrow.clockwise") }
                .accessibilityLabel(L10n.string("mobile.diff.refresh", defaultValue: "Refresh Diff"))
            Button(action: close) { Image(systemName: "xmark") }
                .accessibilityLabel(L10n.string("mobile.diff.close", defaultValue: "Close Diff"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var fileCountLabel: String {
        if fileCount == 1 {
            return L10n.string("mobile.diff.fileCount.one", defaultValue: "1 file")
        }
        return String(
            format: L10n.string("mobile.diff.fileCount.other", defaultValue: "%lld files"),
            locale: Locale.current,
            fileCount
        )
    }
}

private struct MobileDiffContent: View {
    let state: MobileDiffState
    let reload: () -> Void

    var body: some View {
        if let errorMessage = state.errorMessage {
            ContentUnavailableView {
                Label(L10n.string("mobile.diff.loadFailed", defaultValue: "Couldn’t Load Diff"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button(L10n.string("mobile.common.retry", defaultValue: "Retry"), action: reload)
            }
        } else if state.isLoading, state.document == nil {
            ProgressView(L10n.string("mobile.diff.loading", defaultValue: "Loading changes…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if state.document != nil {
            MobileDiffWebView(state: state)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) {
                    if state.isLoading {
                        ProgressView().controlSize(.small).padding(8)
                    }
                }
        } else {
            Color.clear
        }
    }
}

private struct MobileDiffFileList: View {
    let state: MobileDiffState
    let dismiss: () -> Void

    var body: some View {
        let selectedFileID = state.selectedFileID
        NavigationStack {
            List(state.files) { file in
                Button {
                    state.selectFile(id: file.id)
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: file.id == selectedFileID ? "checkmark.circle.fill" : "doc.text")
                            .foregroundStyle(file.id == selectedFileID ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(file.name).foregroundStyle(.primary)
                            Text(file.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        HStack(spacing: 5) {
                            Text(verbatim: "+\(file.added)").foregroundStyle(.green)
                            Text(verbatim: "−\(file.deleted)").foregroundStyle(.red)
                        }
                        .font(.caption.monospacedDigit())
                    }
                }
                .accessibilityIdentifier("MobileDiffFile-\(file.id)")
            }
            .navigationTitle(L10n.string("mobile.diff.files", defaultValue: "Changed Files"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.common.done", defaultValue: "Done"), action: dismiss)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
#endif
