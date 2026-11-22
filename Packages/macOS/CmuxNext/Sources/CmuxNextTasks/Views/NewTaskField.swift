import SwiftUI

/// The title field at the top of the pane: Return sends `task.create`
/// (through the model's intent log) and clears the field for the next one.
/// It takes focus only when the user clicks it or runs New Task.
struct NewTaskField: View {
    let model: TasksModel
    @Environment(\.tasksColors) private var colors
    @State private var title = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus").font(.system(size: 11, weight: .medium)).foregroundStyle(colors.tertiary)
            TextField(TasksStrings.newTaskPlaceholder, text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(colors.primary)
                .focused($focused)
                .onSubmit {
                    if model.createTask(title: title) != nil { title = "" }
                }
                .onKeyPress(.escape) {
                    title = ""
                    focused = false
                    return .handled
                }
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
