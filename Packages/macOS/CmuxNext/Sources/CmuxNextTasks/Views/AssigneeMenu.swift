import SwiftUI

/// The one Assignee control (decision T3): people, then agents, then
/// Unassigned. Used as the detail's assignee menu and as a submenu of the
/// task context menu.
struct AssigneeMenu: View {
    let task: TaskItem
    let model: TasksModel

    var body: some View {
        let choices = model.assigneeChoices
        let me = model.me?.stableID
        Section(TasksStrings.people) {
            ForEach(choices.people, id: \.self) { person in
                item(.person(person), title: person == me ? TasksStrings.me : TaskPrincipal(user: person).shortName)
            }
        }
        Section(TasksStrings.agents) {
            ForEach(choices.agents, id: \.self) { harness in
                item(.agent(harness: harness), title: TaskAssigneeChoices.agentName(harness))
            }
        }
        Divider()
        item(.nobody, title: TasksStrings.unassigned)
    }

    private func item(_ choice: TaskAssigneeChoice, title: String) -> some View {
        Button {
            model.choose(choice, for: task.id)
        } label: {
            if model.isCurrent(choice, for: task) {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

/// Right-click on a task: status choices and the Assignee submenu.
struct TaskContextMenu: View {
    let task: TaskItem
    let model: TasksModel

    var body: some View {
        StatusMenu(task: task, model: model)
        Divider()
        Menu(TasksStrings.assignee) { AssigneeMenu(task: task, model: model) }
    }
}
