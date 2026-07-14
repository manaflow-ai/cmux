#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// Snapshot-only changes tree shared by the root screen and in-diff picker sheet.
struct MobileDiffTreeView: View {
    let snapshot: MobileDiffStatusSnapshot
    let collapsedDirectories: Set<String>
    let tooLargePaths: Set<String>
    let selectedPath: String?
    let toggleDirectory: (String) -> Void
    let selectFile: (String) -> Void

    var body: some View {
        let rows = snapshot.tree.visibleRows(collapsedDirectories: collapsedDirectories)
        ScrollViewReader { proxy in
            List {
                Section {
                    ForEach(rows) { row in
                        MobileDiffTreeRowView(
                            row: row,
                            isCollapsed: directoryPath(row).map(collapsedDirectories.contains) ?? false,
                            isTooLarge: filePath(row).map(tooLargePaths.contains) ?? false,
                            isSelected: filePath(row) == selectedPath,
                            toggleDirectory: toggleDirectory,
                            selectFile: selectFile
                        )
                        .id(row.id)
                    }
                } header: {
                    Text(summary)
                        .textCase(nil)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
            }
            .listStyle(.plain)
            .onAppear { scrollToSelection(proxy) }
            .onChange(of: selectedPath) { _, _ in scrollToSelection(proxy) }
        }
    }

    private var summary: String {
        String(
            format: L10n.string(
                "mobile.diff.summaryFormat",
                defaultValue: "%d files changed  +%d −%d"
            ),
            snapshot.files.count,
            snapshot.totalAdditions,
            snapshot.totalDeletions
        )
    }

    private func directoryPath(_ row: MobileDiffTreeRow) -> String? {
        guard case let .directory(path, _, _, _) = row else { return nil }
        return path
    }

    private func filePath(_ row: MobileDiffTreeRow) -> String? {
        guard case let .file(file, _) = row else { return nil }
        return file.path
    }

    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        guard let selectedPath else { return }
        proxy.scrollTo("file:\(selectedPath)", anchor: .center)
    }
}
#endif
