#if canImport(UIKit)
public import SwiftUI
import CmuxMobileSupport
import Foundation

/// Native iOS chrome around the shared web diff renderer.
public struct MobileDiffPane: View {
    @State private var state: MobileDiffState
    @State private var fileListContext: MobileDiffFileListContext?
    private let onClose: () -> Void
    private let onReload: () -> Void

    /// Creates native controls around the shared web diff renderer.
    public init(
        state: MobileDiffState,
        onClose: @escaping () -> Void,
        onReload: @escaping () -> Void
    ) {
        _state = State(initialValue: state)
        self.onClose = onClose
        self.onReload = onReload
    }

    /// The native mobile diff interface.
    public var body: some View {
        VStack(spacing: 0) {
            MobileDiffNavigationBar(
                selectedFile: state.selectedFile,
                fileCount: state.files.count,
                canSelectPrevious: state.canSelectPrevious,
                canSelectNext: state.canSelectNext,
                showFiles: {
                    fileListContext = MobileDiffFileListContext(
                        files: state.files,
                        selectedFileID: state.selectedFileID
                    )
                },
                selectPrevious: state.selectPrevious,
                selectNext: state.selectNext,
                reload: onReload,
                close: onClose
            )
            Divider()
            MobileDiffContent(state: state, reload: onReload)
        }
        .background(Color(.systemBackground))
        .sheet(item: $fileListContext) { context in
            MobileDiffFileList(
                files: context.files,
                selectedFileID: context.selectedFileID,
                selectFile: { state.selectFile(id: $0) },
                dismiss: { fileListContext = nil }
            )
        }
    }
}

private struct MobileDiffFileListContext: Identifiable {
    let id = UUID()
    let files: [MobileDiffFile]
    let selectedFileID: String?
}
#endif
