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
#endif
