import CmuxNextDesign
import SwiftUI

/// The `cmux://bookmarks` page: folder tree on the left, the folder's
/// bookmarks (or search results) on the right, the usual manager verbs.
/// Undesigned on purpose: system controls, theme colors, density tokens.
struct BookmarkManagerView: View {
    @Bindable var model: BookmarkManagerModel
    @FocusState private var searchFocused: Bool

    private var colors: BookmarkPageColors { model.colors }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            HairlineDivider(color: colors.separator)
            HStack(spacing: 0) {
                folderList
                    .frame(width: Metrics.sidebarWidth)
                HairlineDivider(.vertical, color: colors.separator)
                BookmarkManagerList(model: model)
            }
        }
        .background(colors.background)
        .foregroundStyle(colors.primary)
        .font(Font(Typography.body))
        .sheet(item: $model.editor) { state in
            BookmarkEditorSheet(model: model, state: state)
        }
        .onAppear { searchFocused = true }
    }

    private var toolbar: some View {
        HStack(spacing: Metrics.space4) {
            Text(BookmarkStrings.pageTitle).font(Font(Typography.title))
            Spacer(minLength: Metrics.space6)
            TextField(BookmarkStrings.searchPlaceholder, text: $model.query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .frame(maxWidth: Metrics.paletteWidth / 2)
                .accessibilityIdentifier("cmux.bookmarks.manager.search")
            Menu {
                Button(BookmarkStrings.addBookmark) { model.startAddBookmark() }
                Button(BookmarkStrings.addFolder) { model.startAddFolder() }
                Divider()
                Button(BookmarkStrings.importFromBrowser) { model.source?.importFromBrowser() }
                Button(BookmarkStrings.importHTML) { model.source?.importHTML() }
                Button(BookmarkStrings.exportHTML) { model.source?.exportHTML() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("cmux.bookmarks.manager.menu")
        }
        .padding(.horizontal, Metrics.space6)
        .padding(.vertical, Metrics.space4)
    }

    private var folderList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.space1) {
                ForEach(model.folderChoices) { choice in
                    folderRow(choice)
                }
            }
            .padding(Metrics.space3)
        }
        .accessibilityIdentifier("cmux.bookmarks.manager.folders")
    }

    private func folderRow(_ choice: BookmarkFolderChoice) -> some View {
        let selected = !model.isSearching && model.folder == choice.id
        return HStack(spacing: Metrics.space3) {
            Image(systemName: choice.depth == 0 ? (choice.id == BookmarkRoot.bar.rawValue ? "menubar.rectangle" : "tray") : "folder")
                .foregroundStyle(colors.secondary)
            Text(choice.title).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(choice.depth) * Metrics.space5 + Metrics.space3)
        .padding(.vertical, Metrics.space2)
        .background(RoundedRectangle(cornerRadius: Metrics.itemCornerRadius).fill(selected ? colors.selection : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture {
            model.query = ""
            model.folder = choice.id
            model.selection = []
        }
        .dropDestination(for: String.self) { ids, _ in
            for id in ids where !model.tree.isDescendant(choice.id, of: id) { model.move(id, into: choice.id) }
            return true
        }
        .contextMenu {
            if choice.depth > 0, let node = model.tree.node(choice.id) {
                Button(BookmarkStrings.openAll(model.tree.children(of: node.id).filter { !$0.isFolder }.count)) {
                    model.source?.openAll(in: node.id)
                }
                Button(BookmarkStrings.rename) { model.startEdit(node) }
                Button(BookmarkStrings.delete, role: .destructive) { model.delete([node.id]) }
            } else {
                Button(BookmarkStrings.addFolder) {
                    model.folder = choice.id
                    model.startAddFolder()
                }
            }
        }
    }
}
