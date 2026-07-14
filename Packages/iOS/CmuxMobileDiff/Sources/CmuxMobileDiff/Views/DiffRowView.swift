internal import SwiftUI

struct DiffRowView: View {
    let file: DiffFileSnapshot
    let row: DiffRowSnapshot
    let actions: ChangesScreenActions

    var body: some View {
        switch row.kind {
        case .context, .addition, .deletion:
            DiffCodeRowView(file: file, row: row)
        case .hunkHeader:
            DiffHunkHeaderView(file: file, row: row)
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
