#if os(iOS)
import CmuxMobileShell
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShellUI

@Suite struct TaskComposerSuggestedDirectoryTests {
    @Test @MainActor
    func focusedTerminalDirectoryWinsThePreviousTaskDirectory() throws {
        let suiteName = "TaskComposerSuggestedDirectoryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        store.setLastDirectory("/Users/ui/previous-task", macDeviceID: "mac-a")

        let suggestion = TaskComposerSheet.suggestedDirectory(
            template: nil,
            macDeviceID: "mac-a",
            templateStore: store,
            openDirectory: "/Users/ui/current-project"
        )

        #expect(suggestion == "/Users/ui/current-project")
    }

    @Test @MainActor
    func explicitTemplateDirectoryStillWinsTheFocusedTerminalDirectory() throws {
        let suiteName = "TaskComposerSuggestedDirectoryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        let template = MobileTaskTemplate(
            name: "Project template",
            icon: "terminal",
            command: "",
            defaultDirectory: "/Users/ui/template-project"
        )

        let suggestion = TaskComposerSheet.suggestedDirectory(
            template: template,
            macDeviceID: "mac-a",
            templateStore: store,
            openDirectory: "/Users/ui/current-project"
        )

        #expect(suggestion == "/Users/ui/template-project")
    }
}
#endif
