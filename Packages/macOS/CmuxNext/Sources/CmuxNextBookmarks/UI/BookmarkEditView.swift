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
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space4) {
            Text(model.isNew ? BookmarkStrings.added : BookmarkStrings.editTitle)
                .font(Font(Typography.bodyEmphasized))
                .foregroundStyle(model.colors.primary)
            Grid(alignment: .leading, horizontalSpacing: Metrics.space4, verticalSpacing: Metrics.space3) {
                GridRow {
                    Text(BookmarkStrings.name).foregroundStyle(model.colors.secondary)
                    TextField("", text: $model.title)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .onSubmit { model.onDone() }
                        .accessibilityIdentifier("cmux.bookmarks.edit.name")
                }
                GridRow {
                    Text(BookmarkStrings.folder).foregroundStyle(model.colors.secondary)
                    Picker("", selection: $model.folder) {
                        ForEach(model.folders) { choice in
                            Text(String(repeating: "    ", count: choice.depth) + choice.title).tag(choice.id)
                        }
                    }
                    .labelsHidden()
                    .accessibilityIdentifier("cmux.bookmarks.edit.folder")
                }
            }
            .font(Font(Typography.body))
            HStack(spacing: Metrics.space4) {
                Button(BookmarkStrings.more) { model.onMore() }
                Spacer(minLength: Metrics.space6)
                Button(BookmarkStrings.remove) { model.onRemove() }
                    .accessibilityIdentifier("cmux.bookmarks.edit.remove")
                Button(BookmarkStrings.done) { model.onDone() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("cmux.bookmarks.edit.done")
            }
            .font(Font(Typography.body))
        }
        .padding(Metrics.space5)
        .frame(width: Metrics.paletteWidth * 0.5)
        .onAppear { nameFocused = true }
    }
}
