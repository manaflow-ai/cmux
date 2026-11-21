import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// `-cmux-mobile-no-restore` opens the lists on All Macs with no grouping, so one UI suite's
/// chosen Mac never scopes the next suite's list on the shared simulator.
@Suite struct ListViewStateResetTests {
    /// WorkspaceListGrouping.defaultsKey (CmuxMobileWorkspaces is not this target's dependency).
    private let groupBy = "cmuxMobile.workspaces.groupBy"

    private func defaults() -> UserDefaults {
        let name = "ListViewStateResetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defaults.set("mbp", forKey: MacFilter.keyPrefix + "team-a")
        defaults.set("studio", forKey: MacFilter.keyPrefix + "team-b")
        defaults.set("folder", forKey: groupBy)
        defaults.set("kept", forKey: "cmuxMobile.settings.other")
        return defaults
    }

    @Test func noRestoreClearsTheMacFilterAndGrouping() {
        let defaults = defaults()
        ShellLaunchOptions.clearListViewStateIfNotRestoring(arguments: ["app", "-cmux-mobile-no-restore"], defaults: defaults)
        #expect(defaults.string(forKey: MacFilter.keyPrefix + "team-a") == nil)
        #expect(defaults.string(forKey: MacFilter.keyPrefix + "team-b") == nil)
        #expect(defaults.string(forKey: groupBy) == nil)
        #expect(defaults.string(forKey: "cmuxMobile.settings.other") == "kept")
    }

    @Test func anOrdinaryLaunchKeepsThem() {
        let defaults = defaults()
        ShellLaunchOptions.clearListViewStateIfNotRestoring(arguments: ["app"], defaults: defaults)
        #expect(defaults.string(forKey: MacFilter.keyPrefix + "team-a") == "mbp")
        #expect(defaults.string(forKey: groupBy) == "folder")
    }
}
