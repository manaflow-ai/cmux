import CmuxNextCompat
import Testing
@testable import CmuxNextApp

/// A showcase run's panes name a fixture Mac: the capture scenes' Environment card, composer chip and
/// New Tab page never show the capturing host's computer name (pr-capture's privacy check refused them).
@MainActor
struct ShowcaseMachineNameTests {
    @Test func showcaseNamesTheFixtureMacNotTheHost() async {
        let real = await MacName().displayName()
        let name = await AgentTabStore.localMachineName(showcase: true) { real }
        #expect(name == "Studio Mac")
        #expect(![real, MacName().kernelHostName(), await MacName().computerName()].contains(name))
    }

    @Test func aPersonsRunNamesThisMac() async {
        #expect(await AgentTabStore.localMachineName(showcase: false) { "build-box" } == "build-box")
    }
}
