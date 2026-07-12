#if canImport(UIKit)
public import SwiftUI
import CmuxMobileSupport
import Foundation

/// Native iOS chrome around the shared web diff renderer.
public struct MobileDiffPane: View {
    @State private var state: MobileDiffState
    @State private var showsFiles = false
    @State private var fileListFiles: [MobileDiffFile] = []
    @State private var fileListSelectedFileID: String?
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
                    fileListFiles = state.files
                    fileListSelectedFileID = state.selectedFileID
                    showsFiles = true
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
        .sheet(isPresented: $showsFiles) {
            MobileDiffFileList(
                files: fileListFiles,
                selectedFileID: fileListSelectedFileID,
                selectFile: { state.selectFile(id: $0) },
                dismiss: { showsFiles = false }
            )
        }
    }
}
#endif
