@testable import CmuxNextBrowser
import Foundation
import Testing

/// Host mode: a pane's first window waits for the Chromium Host's verdict on its
/// browser profile's proxy (#24432). Later asks join the wait, a popup makes no second placeholder, an
/// applied verdict asks for the window once, and a refused or missing verdict fails every waiting tab.
/// REPLYs go through the remote shim's sink (``HostRepliesHarness``). Part of
/// CEFRuntimeHostRepliesTests' serialized suite: both read and reset the one spy.
extension CEFRuntimeHostRepliesTests {
    @Test func hostModeAPaneWaitsForTheVerdictAndLaterAsksJoinTheWait() async throws {
        HostRepliesSpy.reset()
        let (runtime, _) = try await HostRepliesHarness.hostRuntime()
        let (pane, endOfTurn) = HostRepliesHarness.pane(runtime, profile: HostRepliesHarness.proxied(runtime))
        let first = HostRepliesHarness.tab(in: pane)
        let second = HostRepliesHarness.tab(in: pane)

        #expect(!pane.ensureCreated(first))
        #expect(pane.window == .awaitingProfileProxy)
        #expect(pane.isCreatingWindow, "a spare waiting for its verdict counts as on its way")
        #expect(!pane.ensureCreated(second))
        #expect(!pane.ensureCreated(first))
        pane.ensureOwnWindow(for: second)
        #expect(pane.tabs.count == 2, "a popup placeholder was made while the pane waits")
        #expect(pane.placeholder == nil)
        #expect(HostRepliesSpy.proxyServers.count == 1, "a later ask sent the proxy again")
        #expect(HostRepliesSpy.createWindowCalls == 0, "the window was asked for before the verdict")

        try HostRepliesHarness.deliver(HostRepliesSpy.tokens[0], CEFReplyWaitersTests.int32(1))
        try HostRepliesHarness.deliver(HostRepliesSpy.tokens[1], CEFReplyWaitersTests.int32(2))
        #expect(HostRepliesSpy.createWindowCalls == 0, "the window was asked for inside the REPLY's delivery")
        endOfTurn.run()

        #expect(HostRepliesSpy.createWindowCalls == 1)
        #expect(pane.isCreatingWindow)
        #expect(first.isCreationPending && second.isCreationPending, "a waiting tab did not join the window")
    }

    @Test func hostModeARefusedVerdictFailsEveryWaitingTab() async throws {
        HostRepliesSpy.reset()
        let (runtime, _) = try await HostRepliesHarness.hostRuntime()
        let (pane, endOfTurn) = HostRepliesHarness.pane(runtime, profile: HostRepliesHarness.proxied(runtime))
        let first = HostRepliesHarness.tab(in: pane)
        let second = HostRepliesHarness.tab(in: pane)
        pane.ensureCreated(first)
        pane.ensureCreated(second)

        try HostRepliesHarness.deliver(HostRepliesSpy.tokens[0], CEFReplyWaitersTests.int32(0))
        try HostRepliesHarness.deliver(HostRepliesSpy.tokens[1], CEFReplyWaitersTests.int32(0))
        endOfTurn.run()

        #expect(HostRepliesSpy.createWindowCalls == 0)
        #expect(pane.window == .none)
        for tab in [first, second] {
            #expect(tab.state.loadError != nil, "a waiting tab of a refused proxy did not fail")
            #expect(!tab.isCreationPending)
        }
    }

    /// A verdict that never comes fails the waiting tab at the reply deadline: the pane shows the
    /// failure instead of staying blank.
    @Test func hostModeAMissingVerdictFailsTheWaitingTabAtTheDeadline() async throws {
        HostRepliesSpy.reset()
        let (runtime, _) = try await HostRepliesHarness.hostRuntime()
        let rig = HostRepliesHarness.deadlines(of: runtime)
        let (pane, endOfTurn) = HostRepliesHarness.pane(runtime, profile: HostRepliesHarness.proxied(runtime))
        let tab = HostRepliesHarness.tab(in: pane)
        pane.ensureCreated(tab)

        try HostRepliesHarness.deliver(HostRepliesSpy.tokens[0], CEFReplyWaitersTests.int32(1))
        rig.advance(by: CEFRuntime.siteReplyTimeout + .seconds(2))
        endOfTurn.run()

        #expect(tab.state.loadError != nil, "a tab waiting for a verdict that never came did not fail")
        #expect(HostRepliesSpy.createWindowCalls == 0)
        #expect(pane.window == .none)
    }

    @Test func hostModeAPaneWhoseTabsClosedWhileWaitingMakesNoWindow() async throws {
        HostRepliesSpy.reset()
        let (runtime, _) = try await HostRepliesHarness.hostRuntime()
        let (pane, endOfTurn) = HostRepliesHarness.pane(runtime, profile: HostRepliesHarness.proxied(runtime))
        let tab = HostRepliesHarness.tab(in: pane)
        pane.ensureCreated(tab)

        pane.removed(tab)
        try HostRepliesHarness.deliver(HostRepliesSpy.tokens[0], CEFReplyWaitersTests.int32(1))
        try HostRepliesHarness.deliver(HostRepliesSpy.tokens[1], CEFReplyWaitersTests.int32(2))
        endOfTurn.run()

        #expect(HostRepliesSpy.createWindowCalls == 0)
        #expect(pane.window == .none)
    }
}
