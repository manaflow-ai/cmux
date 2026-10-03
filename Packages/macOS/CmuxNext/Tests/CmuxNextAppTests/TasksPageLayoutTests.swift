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
}
