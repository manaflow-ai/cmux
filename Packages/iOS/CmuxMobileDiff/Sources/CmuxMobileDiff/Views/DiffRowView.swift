internal import SwiftUI

struct DiffRowView: View {
    let file: DiffFileSnapshot
    let row: DiffRowSnapshot
    let actions: ChangesScreenActions
    let requestNote: (@MainActor @Sendable (DiffFileSnapshot, DiffRowSnapshot, DiffNoteSelectionScope) -> Void)?

    var body: some View {
        if isSourceLine, let requestNote {
            rowContent
                .contentShape(Rectangle())
                .onLongPressGesture {
                    requestNote(file, row, .line)
                }
        } else {
            rowContent
        }
    }

    @ViewBuilder
    private var rowContent: some View {
        if row.splitOldSide != nil || row.splitNewSide != nil {
            DiffSplitCodeRowView(file: file, row: row)
        } else {
            switch row.kind {
            case .context, .addition, .deletion:
                DiffCodeRowView(file: file, row: row)
            case .hunkHeader:
                DiffHunkHeaderView(file: file, row: row, requestNote: requestNote)
            case .expansionGap:
                DiffExpansionGapView(file: file, row: row, expand: actions.expandGap)
            case .noNewline:
                DiffNoNewlineRowView(file: file)
            case .binary, .largeDiff, .renameOnly, .tooLarge, .loading, .error:
                DiffPlaceholderRowView(file: file, row: row, retry: actions.loadFile)
            case .fileHeader:
                EmptyView()
            }
        }
    }

    private var isSourceLine: Bool {
        if row.splitOldSide != nil || row.splitNewSide != nil { return true }
        return switch row.kind {
        case .context, .addition, .deletion: true
        default: false
        }
    }
}
