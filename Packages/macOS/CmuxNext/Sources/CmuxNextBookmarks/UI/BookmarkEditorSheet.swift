import CmuxNextDesign
import SwiftUI

/// Add or edit a bookmark or folder from the manager: Name, URL (bookmarks
/// only), Folder. Return saves; Escape cancels.
struct BookmarkEditorSheet: View {
    let model: BookmarkManagerModel
    @State var state: BookmarkEditorState
    @Environment(\.dismiss) private var dismiss

    init(model: BookmarkManagerModel, state: BookmarkEditorState) {
        self.model = model
        _state = State(initialValue: state)
    }

    private var heading: String {
        switch state.mode {
        case .addBookmark: BookmarkStrings.addBookmark
        case .addFolder: BookmarkStrings.addFolder
        case .edit: state.isFolder ? BookmarkStrings.rename : BookmarkStrings.editTitle
        }
    }

    /// Folders the node may go to (not itself or below it).
    private var choices: [BookmarkFolderChoice] {
        guard case .edit(let id) = state.mode, state.isFolder else { return model.folderChoices }
        return model.folderChoices.filter { !model.tree.isDescendant($0.id, of: id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space5) {
            Text(heading).font(Font(Typography.bodyEmphasized))
            Grid(alignment: .leading, horizontalSpacing: Metrics.space4, verticalSpacing: Metrics.space3) {
                GridRow {
                    Text(BookmarkStrings.name)
                    TextField("", text: $state.title).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("cmux.bookmarks.editor.name")
                }
                if !state.isFolder {
                    GridRow {
                        Text(BookmarkStrings.url)
                        TextField("", text: $state.url).textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("cmux.bookmarks.editor.url")
                    }
                }
                GridRow {
                    Text(BookmarkStrings.folder)
                    Picker("", selection: $state.folder) {
                        ForEach(choices) { choice in
                            Text(String(repeating: "    ", count: choice.depth) + choice.title).tag(choice.id)
                        }
                    }
                    .labelsHidden()
                }
            }
            if let error = model.errorMessage {
                Text(error).foregroundStyle(model.colors.danger)
            }
            HStack {
                Spacer()
                Button(BookmarkStrings.cancel) {
                    model.errorMessage = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(BookmarkStrings.save) {
                    if model.commitEditor(state) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("cmux.bookmarks.editor.save")
            }
        }
        .font(Font(Typography.body))
        .padding(Metrics.space6)
        .frame(width: Metrics.paletteWidth * 0.7)
    }
}
