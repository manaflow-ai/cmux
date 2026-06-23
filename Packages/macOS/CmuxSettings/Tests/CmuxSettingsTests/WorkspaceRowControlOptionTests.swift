import Foundation
import Testing
@testable import CmuxSettings

@Suite("sidebar.workspaceControls")
struct WorkspaceRowControlOptionTests {
    private func makeStore() -> (UserDefaultsSettingsStore, String, SettingCatalog) {
        let suiteName = "cmux.workspaceControls.tests.\(UUID().uuidString)"
        let store = UserDefaultsSettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        return (store, suiteName, SettingCatalog())
    }

    @Test func sanitizedAlwaysIncludesCloseAndCapsControls() {
        let controls = WorkspaceRowControlSanitizer().sanitized([.tasks, .tasks, .close])
        #expect(controls == [.tasks, .close])

        let missingClose = WorkspaceRowControlSanitizer().sanitized([.tasks])
        #expect(missingClose == [.close, .tasks])
    }

    @Test func sanitizedRawValuesDropsUnknownEntries() {
        let controls = WorkspaceRowControlSanitizer().sanitizedRawValues(["tasks", "unknown", "close", "tasks"])
        #expect(controls == [.tasks, .close])
    }

    @Test func sanitizedPrioritizesCloseWhenCapWouldExcludeIt() {
        let controls = WorkspaceRowControlSanitizer(maximumVisibleControls: 1).sanitized([.tasks, .close])
        #expect(controls == [.close])
    }

    @Test func defaultsToCloseWhenUnset() async {
        let (store, _, catalog) = makeStore()
        let value = await store.value(for: catalog.sidebar.workspaceControls)
        #expect(value == [.close])
    }

    @Test func roundTripsThroughTheStore() async {
        let (store, suiteName, catalog) = makeStore()
        await store.set([.close, .tasks], for: catalog.sidebar.workspaceControls)
        let value = await store.value(for: catalog.sidebar.workspaceControls)
        #expect(value == [.close, .tasks])
        let defaults = UserDefaults(suiteName: suiteName)!
        #expect(defaults.stringArray(forKey: catalog.sidebar.workspaceControls.userDefaultsKey) == ["close", "tasks"])
    }
}
