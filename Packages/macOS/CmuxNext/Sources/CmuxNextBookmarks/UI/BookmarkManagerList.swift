import CmuxNextDesign
import CmuxNextIcons
import SwiftUI

/// The right side of the manager: rows with icon, title, URL and folder
/// path (while searching). Double-click or Return opens; drag a row onto
/// another to put it before that row, onto a folder row to move it in;
/// Delete removes the selection.
struct BookmarkManagerList: View {
    @Bindable var model: BookmarkManagerModel

    private var colors: BookmarkPageColors { model.colors }

    var body: some View {
        let rows = model.rows
        Group {
            if rows.isEmpty {
                VStack {
                    Spacer()
                    VStack(spacing: Metrics.space2) {
                        Text(model.isSearching ? BookmarkStrings.emptySearchTitle : BookmarkStrings.emptyPageTitle)
                            .font(Font(Typography.bodyEmphasized))
                            .foregroundStyle(colors.primary)
                        Text(model.isSearching ? BookmarkStrings.emptySearchHint : BookmarkStrings.emptyPageHint)
                            .foregroundStyle(colors.secondary)
                    }
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Metrics.space6)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(selection: $model.selection) {
                    ForEach(rows) { node in
                        row(node)
                            .tag(node.id)
                            .listRowBackground(Color.clear)
                            .thinScrollers()
                    }
                }
                .scrollContentBackground(.hidden)
                .onDeleteCommand { model.delete(model.selection) }
                .contextMenu(forSelectionType: String.self) { ids in
                    menu(for: ids)
                } primaryAction: { ids in
                    for id in ids { if let node = model.tree.node(id) { model.activate(node) } }
                }
                .accessibilityIdentifier("cmux.bookmarks.manager.list")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ node: BookmarkNode) -> some View {
        HStack(spacing: Metrics.space4) {
            BookmarkNodeIcon(node: node, source: model.source, color: colors.secondary)
                .frame(width: Metrics.iconSize)
            Text(node.displayTitle).lineLimit(1)
            if let url = node.url, !node.title.isEmpty {
                Text(BookmarkURL.displayText(url))
                    .lineLimit(1)
                    .foregroundStyle(colors.tertiary)
            }
            Spacer(minLength: Metrics.space4)
            if model.isSearching {
                Text(model.tree.folderPath(of: node.id).map(folderName).joined(separator: " › "))
                    .lineLimit(1)
                    .foregroundStyle(colors.tertiary)
            }
        }
        .padding(.vertical, Metrics.space1)
        .draggable(node.id)
        .dropDestination(for: String.self) { ids, _ in
            for id in ids { model.drop(id, on: node) }
            return true
        }
    }

    private func folderName(_ component: String) -> String {
        switch BookmarkRoot(rawValue: component) {
        case .bar: BookmarkStrings.barTitle
        case .other: BookmarkStrings.otherBookmarks
        case nil: component
        }
    }

    @ViewBuilder
    private func menu(for ids: Set<String>) -> some View {
        let nodes = ids.compactMap { model.tree.node($0) }
        if nodes.count == 1, let node = nodes.first {
            if node.isFolder {
                Button(BookmarkStrings.openAll(model.tree.children(of: node.id).filter { !$0.isFolder }.count)) {
                    model.source?.openAll(in: node.id)
                }
                Button(BookmarkStrings.rename) { model.startEdit(node) }
                BookmarkFolderIconMenuItems(node: node, source: model.source)
            } else {
                Button(BookmarkStrings.open) { model.source?.open(node, disposition: .currentTab) }
                Button(BookmarkStrings.openInNewTab) { model.source?.open(node, disposition: .newTab) }
                Button(BookmarkStrings.openInBackgroundTab) { model.source?.open(node, disposition: .backgroundTab) }
                Divider()
                Button(BookmarkStrings.edit) { model.startEdit(node) }
                if let url = node.url { Button(BookmarkStrings.copyURL) { model.source?.copy(url.absoluteString) } }
            }
            if model.isSearching {
                Button(BookmarkStrings.showInFolder) {
                    model.query = ""
                    model.folder = node.parent
                    model.selection = [node.id]
                }
            }
            Divider()
        }
        if !nodes.isEmpty {
            Button(BookmarkStrings.delete, role: .destructive) { model.delete(ids) }
        }
        if nodes.isEmpty {
            Button(BookmarkStrings.addBookmark) { model.startAddBookmark() }
            Button(BookmarkStrings.addFolder) { model.startAddFolder() }
        }
    }
}
