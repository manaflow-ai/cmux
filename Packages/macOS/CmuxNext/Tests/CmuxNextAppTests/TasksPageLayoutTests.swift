import CmuxNextSettings
import CmuxNextTasks
import Testing
@testable import CmuxNextApp

/// The Tasks page follows `tasks.layout`: every setting value maps to the
/// pane layout of the same name, and no settings means the default.
@MainActor
@Suite struct TasksPageLayoutTests {
    @Test func everySettingValueHasItsLayout() {
        #expect(TasksLayoutPreference.allCases.map(\.rawValue) == TasksLayout.allCases.map(\.rawValue))
        #expect(TasksLayoutSetting.fallback.rawValue == TasksLayout.fallback.rawValue)
    }

    @Test func withoutSettingsThePageShowsTheDefault() {
        #expect(TasksPageService.layout(nil) == .inbox)
    }

    @Test func thePageIsALocalPageTab() {
        let key = LocalPageTab.makeKey(.tasks)
        #expect(key.hasPrefix("local-page:tasks:"))
        #expect(LocalPageTab.page(of: key) == .tasks)
    }

    /// Origin rule: an automation run (CLI, MCP, script, remote) opens the
    /// page but never changes the scope or focuses the New Task field.
    @Test func automationRunsLeaveTheViewAsItIs() {
        let model = TasksModel(source: MockTasksSource())
        model.start()
        TasksPageService.applyViewState(scope: .mine, newTask: true, focus: false, to: model)
        #expect(model.scope == .all)
        #expect(model.newTaskFocusRequest == 0)
        TasksPageService.applyViewState(scope: .mine, newTask: true, focus: true, to: model)
        #expect(model.scope == .mine)
        #expect(model.newTaskFocusRequest == 1)
        TasksPageService.applyViewState(scope: nil, newTask: false, focus: true, to: model)
        #expect(model.scope == .mine, "nil keeps the scope")
    }
}
