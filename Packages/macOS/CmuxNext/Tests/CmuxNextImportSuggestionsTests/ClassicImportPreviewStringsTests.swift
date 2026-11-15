@testable import CmuxNextImportSuggestions
import Foundation
import Testing

/// The classic import prompt reads as sentences (Leo 2026-11-15, on the label-and-number list it replaced: "this is
/// kinda strange. what happened here?"): what comes over with no zero counts, what opening it does, no caution that
/// does not apply, and at launch where the import waits.
struct ClassicImportPreviewStringsTests {
    typealias Strings = ClassicImportPreviewStrings

    @Test func leosSaveReadsAsThreeSentencesWithoutZeroCounts() {
        let lines = Strings.lines(.init(workspaces: 8, browserTabs: 2, agentChats: 1), app: "cmux", savedAt: Date(),
                                  classicRunning: false, atLaunch: true)
        #expect(lines.count == 3, "\(lines)")
        #expect(lines[0].hasPrefix(Strings.workspaces(8)), "\(lines)")
        #expect(lines[0].contains(Strings.browserTabs(2)) && lines[0].contains(Strings.agentChats(1)), "\(lines)")
        #expect(!lines[0].contains(Strings.sshWorkspaces(0)) && !lines[0].contains(Strings.filePages(0)), "\(lines)")
        #expect(lines[1].contains(Strings.pagesLoad) && lines[1].contains(Strings.chatsResume) && !lines[1].contains(Strings.hostsConnect),
                "\(lines)")
        #expect(lines[2] == Strings.later)
    }

    @Test func onlyTheLaunchSaysWhereTheImportWaits() {
        let counts = Strings.Counts(workspaces: 3)
        let manual = Strings.lines(counts, app: "cmux", savedAt: Date(), classicRunning: false, atLaunch: false)
        #expect(manual == [Strings.summary(counts, app: "cmux", savedAt: Date(), classicRunning: false), Strings.opensAsSaved])
    }

    @Test func cautionsShowOnlyWhenTheyApply() {
        let counts = Strings.Counts(workspaces: 12, sshWorkspaces: 2, skippedCloudVMs: 2, cleanup: 3)
        let lines = Strings.lines(counts, app: "cmux NIGHTLY", savedAt: Date(), classicRunning: true, atLaunch: false)
        #expect(lines.contains(String(format: Strings.stillOpen, "cmux NIGHTLY")), "\(lines)")
        #expect(lines.contains(Strings.cloudVMsSkipped(2)) && lines.last == Strings.interruptedClose(3), "\(lines)")
        #expect(lines[1].contains(Strings.hostsConnect) && !lines[1].contains(Strings.pagesLoad), "\(lines)")
    }

    @Test func appNameFollowsTheClassicChannel() {
        #expect(Strings.appName("com.cmuxterm.app") == "cmux")
        #expect(Strings.appName("com.cmuxterm.app.nightly") == "cmux NIGHTLY")
        #expect(Strings.appName("com.cmuxterm.app.debug.foo") == "cmux DEV")
    }
}
