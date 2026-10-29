import AppKit
import CmuxNextDesign
import CmuxNextIcons
import SwiftUI

/// The title field at the top of the pane: Return sends `task.create`
/// (through the model's intent log) and clears the field for the next one.
/// It takes focus only when the user clicks it or runs New Task. A themed
/// field: its text, caret and placeholder are the scope's inks.
struct NewTaskField: View {
    let model: TasksModel
    @Environment(\.tasksColors) private var colors
    /// The model's `newTaskDraft`: a typed title outlives this view.
    @Binding private var title: String
    @State private var focused = false

    init(model: TasksModel) {
        self.model = model
        _title = Bindable(model).newTaskDraft
    }

    var body: some View {
        HStack(spacing: 8) {
            Icon(.actionAdd, size: 14).foregroundStyle(colors.tertiary)
            ThemedField(text: $title, placeholder: TasksStrings.newTaskPlaceholder, font: .systemFont(ofSize: 12.5),
                        height: 18, boxed: false, isFocused: $focused,
                        onSubmit: { if model.createTask(title: title) != nil { title = "" } },
                        onCancel: {
                            title = ""
                            focused = false
                        })
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(focused ? colors.hover : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(colors.separator).frame(height: 1) }
        .onChange(of: model.newTaskFocusRequest) { honorFocusRequest() }
        .onAppear { honorFocusRequest() }
    }

    private func honorFocusRequest() {
        if model.takeNewTaskFocusRequest() { focused = true }
    }
}
