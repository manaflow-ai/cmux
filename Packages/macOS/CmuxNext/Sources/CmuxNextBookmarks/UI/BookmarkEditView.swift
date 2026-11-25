import CmuxNextDesign
import Observation
import SwiftUI

@Observable
final class BookmarkEditModel {
    let isNew: Bool
    var title: String
    var folder: String
    let folders: [BookmarkFolderChoice]
    var colors = BookmarkPageColors()
    @ObservationIgnored var onDone: () -> Void = {}
    @ObservationIgnored var onRemove: () -> Void = {}
    @ObservationIgnored var onMore: () -> Void = {}

    init(isNew: Bool, title: String, folder: String, folders: [BookmarkFolderChoice]) {
        self.isNew = isNew
        self.title = title
        self.folder = folder
        self.folders = folders
    }
}

/// The bubble's form: undesigned, compact, theme colors only.
struct BookmarkEditView: View {
    @Bindable var model: BookmarkEditModel

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space4) {
            Text(model.isNew ? BookmarkStrings.added : BookmarkStrings.editTitle)
                .font(Font(Typography.bodyEmphasized))
                .foregroundStyle(model.colors.primary)
            Grid(alignment: .leading, horizontalSpacing: Metrics.space4, verticalSpacing: Metrics.space3) {
                GridRow {
                    Text(BookmarkStrings.name).foregroundStyle(model.colors.secondary)
                    ThemedField(text: $model.title, focusOnAppear: true, identifier: "cmux.bookmarks.edit.name",
                                onSubmit: { model.onDone() })
                }
                GridRow {
                    Text(BookmarkStrings.folder).foregroundStyle(model.colors.secondary)
                    ThemedPicker(selection: $model.folder, choices: model.folders.map {
                        ThemedPicker.Choice(id: $0.id, title: String(repeating: "    ", count: $0.depth) + $0.title)
                    }, identifier: "cmux.bookmarks.edit.folder")
                }
            }
            .font(Font(Typography.body))
            HStack(spacing: Metrics.space4) {
                Button(BookmarkStrings.more) { model.onMore() }
                Spacer(minLength: Metrics.space6)
                Button(BookmarkStrings.remove) { model.onRemove() }
                    .accessibilityIdentifier("cmux.bookmarks.edit.remove")
                CmuxDialogActionButton(BookmarkStrings.done, hint: .return) { model.onDone() }
                    .accessibilityIdentifier("cmux.bookmarks.edit.done")
            }
            .font(Font(Typography.body))
        }
        .padding(Metrics.space5)
        .frame(width: Metrics.paletteWidth * 0.5)
        // The default button in the theme's selection fill, never the system blue (cx-wqn5).
        .tint(model.colors.selection)
    }
}
