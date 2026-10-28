@testable import CmuxNextBrowser
import Foundation
import Testing

/// The token form of the async exports in CEFRuntime (task 021 of
/// plans/cmux-next/chrome-parity/p01-process.md): in process a call returns its answer; in host mode
/// it returns once sent, and the answer comes in the host's REPLY, which the remote shim hands to
/// `CEFHostStart.replies` through its reply callback (task 018). Every host-mode case here attaches a
/// real `CEFHostStart` to a spy remote dylib and delivers each REPLY through the C callback that
/// `cmux_remote_shim_set_reply` was given, the path the host's frames take.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct CEFRuntimeHostRepliesTests {
    // MARK: In process: the call is the answer

    @Test func inProcessTheCallIsTheAnswer() async throws {
        HostRepliesSpy.reset()
        HostRepliesSpy.contentSettingResult = CEFContentSetting.block.rawValue
        let runtime = try HostRepliesHarness.inProcessRuntime()

        let sent = runtime.sendAsync { shim in shim.contentSetting(1, nil, "camera") }
        guard case .now(let raw) = sent else {
            Issue.record("in process sent \(sent), expected .now")
            return
        }
        #expect(raw == CEFContentSetting.block.rawValue)
        #expect(await runtime.contentSetting(1, url: nil, kind: .camera) == .block)
    }

    @Test func inProcessACallbackRunsInTheCall() throws {
        HostRepliesSpy.reset()
        HostRepliesSpy.contentSettingResult = CEFContentSetting.allow.rawValue
        let runtime = try HostRepliesHarness.inProcessRuntime()
        var seen: [CEFContentSetting?] = []

        runtime.contentSetting(1, url: nil, kind: .camera) { seen.append($0) }

        #expect(seen == [.allow])
    }

    @Test func inProcessAProfileProxyGateIsDecidedInTheCall() throws {
        HostRepliesSpy.reset()
        let runtime = try HostRepliesHarness.inProcessRuntime()
        let profile = HostRepliesHarness.proxied(runtime)

        #expect(runtime.applyProfileProxy(profile) == .open)
        #expect(HostRepliesSpy.proxyServers == ["http://proxy.test:8080"])
        #expect(runtime.profileProxyChecks.isEmpty, "in process kept a host verdict")

        runtime.unappliedProfileProxies.insert(profile)
        HostRepliesSpy.setProxyResult = 0
        #expect(runtime.applyProfileProxy(profile) == .refused)
        #expect(runtime.unappliedProfileProxies.contains(profile), "a refused proxy is not handed over again")
    }

    // MARK: Host mode: the REPLY through the remote shim's sink is the answer

    @Test func hostModeTheSinksReplyAnswersTheAwaitingCall() async throws {
        HostRepliesSpy.reset()
        let (runtime, host) = try await HostRepliesHarness.hostRuntime()

        let asked = Task { await runtime.contentSetting(1, url: "https://a.test", kind: .camera) }
        await CEFReplyWaitersTests.afterQueuedWork()
        #expect(host.replies.awaiting == 1)
        try HostRepliesHarness.deliver(HostRepliesSpy.lastToken, CEFReplyWaitersTests.int32(CEFContentSetting.ask.rawValue))

        #expect(await asked.value == .ask)
        #expect(host.replies.count == 0)
    }

    /// The REPLY may come before the caller awaits: `sendAsync` expected its token in the call's turn.
    @Test func hostModeAReplyBeforeTheAwaitIsKept() async throws {
        HostRepliesSpy.reset()
        let (runtime, host) = try await HostRepliesHarness.hostRuntime()

        let sent = runtime.sendAsync { shim in shim.contentSetting(1, nil, "camera") }
        guard case .later(let token) = sent else {
            Issue.record("host mode sent \(sent), expected .later")
            return
        }
        #expect(token == HostRepliesSpy.lastToken)
        try HostRepliesHarness.deliver(token, CEFReplyWaitersTests.int32(CEFContentSetting.allow.rawValue))

        #expect(try await runtime.answer(sent, label: "content setting") == CEFContentSetting.allow.rawValue)
        #expect(host.replies.count == 0)
    }

    /// Page Info's reads go out in one turn: every token is sent before any answer is awaited.
    @Test func hostModeContentSettingsAreSentInOneTurn() async throws {
        HostRepliesSpy.reset()
        let (runtime, _) = try await HostRepliesHarness.hostRuntime()

        let asked = Task { await runtime.contentSettings(1, [("https://a.test", .camera), (nil, .camera), ("https://a.test", .microphone)]) }
        await CEFReplyWaitersTests.afterQueuedWork()
        #expect(HostRepliesSpy.tokens.count == 3, "a read waited for the answer before the next was sent")
        try HostRepliesHarness.deliver(HostRepliesSpy.tokens[2], CEFReplyWaitersTests.int32(CEFContentSetting.block.rawValue))
        try HostRepliesHarness.deliver(HostRepliesSpy.tokens[0], CEFReplyWaitersTests.int32(CEFContentSetting.allow.rawValue))
        try HostRepliesHarness.deliver(HostRepliesSpy.tokens[1], CEFReplyWaitersTests.int32(-1))

        #expect(await asked.value == [.allow, nil, .block])
    }

    /// A caller in a synchronous turn gets the answer in the turn that delivers the REPLY: no task.
    @Test func hostModeACallbackRunsInTheTurnTheSinkDeliversTheReply() async throws {
        HostRepliesSpy.reset()
        let (runtime, host) = try await HostRepliesHarness.hostRuntime()
        var seen: [CEFContentSetting?] = []

        runtime.contentSetting(1, url: nil, kind: .camera) { seen.append($0) }
        #expect(seen.isEmpty, "the callback ran before the host answered")
        try HostRepliesHarness.deliver(HostRepliesSpy.lastToken, CEFReplyWaitersTests.int32(CEFContentSetting.block.rawValue))
        #expect(seen == [.block])
        try HostRepliesHarness.deliver(HostRepliesSpy.lastToken, CEFReplyWaitersTests.int32(CEFContentSetting.allow.rawValue))
        #expect(seen == [.block], "a callback ran twice")

        runtime.contentSetting(1, url: nil, kind: .camera) { seen.append($0) }
        try HostRepliesHarness.deliver(HostRepliesSpy.lastToken, CEFReplyWaitersTests.int32(1) + CEFReplyWaitersTests.int32(2))
        #expect(seen == [.block, nil], "a reply of the wrong shape is no answer")

        runtime.contentSetting(1, url: nil, kind: .camera) { seen.append($0) }
        runtime.hostGone()
        #expect(seen == [.block, nil, nil], "the host's exit left a callback waiting")
        #expect(host.replies.count == 0)
    }

    /// A REPLY that never comes (the host hangs or drops it) fails the callback at the reply deadline,
    /// an entry on the runtime's main deadline queue, and leaves nothing in the table.
    @Test func hostModeACallbackWithNoReplyFailsAtItsDeadline() async throws {
        HostRepliesSpy.reset()
        let (runtime, host) = try await HostRepliesHarness.hostRuntime()
        let rig = HostRepliesHarness.deadlines(of: runtime)
        var answers: [CEFContentSetting?] = []

        runtime.contentSetting(1, url: nil, kind: .camera) { answers.append($0) }
        rig.advance(by: CEFRuntime.siteReplyTimeout - .milliseconds(1))
        #expect(answers.isEmpty, "the deadline fired before its time")
        #expect(host.replies.count == 1)
        rig.advance(by: .seconds(2))

        #expect(answers == [nil])
        #expect(host.replies.count == 0)
        try HostRepliesHarness.deliver(HostRepliesSpy.lastToken, CEFReplyWaitersTests.int32(CEFContentSetting.allow.rawValue))
        #expect(answers == [nil], "a late REPLY ran the callback again")
    }

    /// A call that sent no op for a reply (a mint, or one the remote refused before the wire) leaves
    /// the remote's last token as it was: `.unsent`, never the token of an earlier call.
    @Test func hostModeACallThatSentNoReplyOpIsUnsent() async throws {
        HostRepliesSpy.reset()
        let (runtime, host) = try await HostRepliesHarness.hostRuntime()
        runtime.contentSetting(1, url: nil, kind: .camera) { _ in }
        #expect(HostRepliesSpy.lastToken != 0)

        let minted = runtime.sendAsync { shim in shim.tabAdd(1, nil, -1, 0) }
        guard case .unsent = minted else {
            Issue.record("a mint in sendAsync returned \(minted), expected .unsent")
            return
        }
        HostRepliesSpy.sendsNothing = true
        let refused = runtime.sendAsync { shim in shim.contentSetting(1, nil, "camera") }
        guard case .unsent = refused else {
            Issue.record("a refused call returned \(refused), expected .unsent")
            return
        }
        await #expect(throws: BrowserTabError.closed) { try await runtime.answer(refused, label: "content setting") }
        #expect(host.replies.count == 1, "only the first call's token is expected")
    }

    /// A CMUX_SHIM_REPLY op whose start the host refused fails at once, not at the 5 s deadline.
    @Test func hostModeARefusedStartFailsTheSiteCallAtOnce() async throws {
        HostRepliesSpy.reset()
        let (runtime, _) = try await HostRepliesHarness.hostRuntime()

        let visit = Task { try await runtime.cookies(1) }
        await CEFReplyWaitersTests.afterQueuedWork()
        #expect(HostRepliesSpy.visits == 1)
        try HostRepliesHarness.deliver(HostRepliesSpy.lastToken, CEFReplyWaitersTests.int32(0))

        await #expect(throws: BrowserTabError.closed) { try await visit.value }
    }

    /// The site reply may come before the start's REPLY: it waits in earlySiteReplies.
    @Test func hostModeAStartedSiteCallTakesItsSiteReply() async throws {
        HostRepliesSpy.reset()
        let (runtime, _) = try await HostRepliesHarness.hostRuntime()

        let delete = Task { try await runtime.deleteCookies(1, url: "https://a.test/", name: nil) }
        await CEFReplyWaitersTests.afterQueuedWork()
        let id = try #require(runtime.siteReplyBrowsers.keys.first)
        // The CMUX_SHIM_REPLY event under the site reply id, as CEFRuntime+Events handles it.
        runtime.earlySiteReplies[id] = CEFSiteReply(value: 3, json: "")
        try HostRepliesHarness.deliver(HostRepliesSpy.lastToken, CEFReplyWaitersTests.int32(1))

        #expect(try await delete.value == 3)
    }

    // MARK: Host mode: profile proxies

    /// No page of a proxied profile opens before the host applied its proxy (fail closed).
    @Test func hostModeAProfileProxyWaitsForBothVerdicts() async throws {
        HostRepliesSpy.reset()
        let (runtime, _) = try await HostRepliesHarness.hostRuntime()
        let profile = HostRepliesHarness.proxied(runtime)
        var verdicts: [Bool] = []

        #expect(runtime.applyProfileProxy(profile) == .waiting)
        #expect(HostRepliesSpy.proxyServers == ["http://proxy.test:8080"])
        #expect(HostRepliesSpy.tokens.count == 2, "the proxy and its state were not both sent")
        runtime.whenProfileProxyApplied(profile) { verdicts.append($0) }
        #expect(HostRepliesSpy.proxyServers.count == 1, "a second page sent the proxy again")

        try HostRepliesHarness.deliver(HostRepliesSpy.tokens[0], CEFReplyWaitersTests.int32(1))
        #expect(verdicts.isEmpty, "the page opened before the proxy's state came")
        try HostRepliesHarness.deliver(HostRepliesSpy.tokens[1], CEFReplyWaitersTests.int32(0))

        #expect(verdicts == [true])
        #expect(runtime.applyProfileProxy(profile) == .open)
        #expect(HostRepliesSpy.tokens.count == 2, "an applied proxy was asked again")
    }

    @Test func hostModeARefusedProfileProxyFailsClosedAndIsHandedOverAgain() async throws {
        HostRepliesSpy.reset()
        let (runtime, _) = try await HostRepliesHarness.hostRuntime()
        let profile = HostRepliesHarness.proxied(runtime)
        var verdicts: [Bool] = []

        runtime.whenProfileProxyApplied(profile) { verdicts.append($0) }
        try HostRepliesHarness.deliver(HostRepliesSpy.tokens[0], CEFReplyWaitersTests.int32(0))
        try HostRepliesHarness.deliver(HostRepliesSpy.tokens[1], CEFReplyWaitersTests.int32(0))

        #expect(verdicts == [false])
        #expect(runtime.profileProxyChecks[profile] == nil)
        #expect(runtime.unappliedProfileProxies.contains(profile))
        runtime.whenProfileProxyApplied(profile) { verdicts.append($0) }
        #expect(HostRepliesSpy.proxyServers.count == 2, "the next page did not hand the proxy over again")
        try HostRepliesHarness.deliver(HostRepliesSpy.tokens[2], CEFReplyWaitersTests.int32(1))
        try HostRepliesHarness.deliver(HostRepliesSpy.tokens[3], CEFReplyWaitersTests.int32(0))
        #expect(verdicts == [false, true])
    }

    /// One REPLY that never comes refuses the waiting pages at the deadline and drops the check, so the
    /// next page hands the proxy over again instead of reusing a verdict that never came.
    @Test func hostModeAProfileProxyWithAMissingReplyFailsClosedAtTheDeadline() async throws {
        HostRepliesSpy.reset()
        let (runtime, _) = try await HostRepliesHarness.hostRuntime()
        let rig = HostRepliesHarness.deadlines(of: runtime)
        let profile = HostRepliesHarness.proxied(runtime)
        var verdicts: [Bool] = []

        runtime.whenProfileProxyApplied(profile) { verdicts.append($0) }
        try HostRepliesHarness.deliver(HostRepliesSpy.tokens[0], CEFReplyWaitersTests.int32(1))
        rig.advance(by: CEFRuntime.siteReplyTimeout + .seconds(2))

        #expect(verdicts == [false])
        #expect(runtime.profileProxyChecks[profile] == nil)
        #expect(runtime.applyProfileProxy(profile) == .waiting)
        #expect(HostRepliesSpy.proxyServers.count == 2, "the next page did not hand the proxy over again")
    }

    /// An open verdict was the exited host's: after the host goes, the next page hands the proxy over
    /// to the next host again and waits for its verdict (#24432 fails closed).
    @Test func hostModeAnOpenProfileProxyIsHandedOverAgainAfterTheHostExits() async throws {
        HostRepliesSpy.reset()
        let (runtime, _) = try await HostRepliesHarness.hostRuntime()
        let profile = HostRepliesHarness.proxied(runtime)
        #expect(runtime.applyProfileProxy(profile) == .waiting)
        try HostRepliesHarness.deliver(HostRepliesSpy.tokens[0], CEFReplyWaitersTests.int32(1))
        try HostRepliesHarness.deliver(HostRepliesSpy.tokens[1], CEFReplyWaitersTests.int32(2))
        #expect(runtime.applyProfileProxy(profile) == .open)

        runtime.hostGone()

        #expect(runtime.applyProfileProxy(profile) == .waiting)
        #expect(HostRepliesSpy.proxyServers == ["http://proxy.test:8080", "http://proxy.test:8080"])
    }

    // MARK: Host mode: SSL status

    /// The SSL status of a page the tab has navigated away from by the time the REPLY comes is not
    /// applied to the page it shows now.
    @Test func hostModeAnSSLStatusForAPageNavigatedAwayIsNotApplied() async throws {
        HostRepliesSpy.reset()
        let (runtime, _) = try await HostRepliesHarness.hostRuntime()
        let (pane, _) = HostRepliesHarness.pane(runtime, profile: .default)
        let tab = HostRepliesHarness.tab(in: pane)
        runtime.register(tab, browser: 7)
        let broken = CEFReplyWaitersTests.string(#"{"certStatus": 1}"#)

        HostRepliesHarness.commit(tab, "https://a.test/")
        let before = tab.state.security
        tab.syncSecurityFromChromium()
        let stale = HostRepliesSpy.lastToken
        HostRepliesHarness.commit(tab, "https://b.test/")
        try HostRepliesHarness.deliver(stale, broken)
        #expect(tab.state.security == before, "a stale SSL status changed the shown page's security")

        tab.syncSecurityFromChromium()
        try HostRepliesHarness.deliver(HostRepliesSpy.lastToken, broken)
        #expect(tab.state.security == .broken)
    }
}
