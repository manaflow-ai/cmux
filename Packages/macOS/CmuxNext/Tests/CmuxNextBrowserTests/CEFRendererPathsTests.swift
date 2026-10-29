import AppKit
@testable import CmuxNextBrowser
@testable import CmuxNextCompat
import CmuxNextWakeups
import Foundation
import os
import Testing

/// Chrome shares a renderer between at most 2 main frames of one site (kProcessPerSiteUpToMainFrameThreshold),
/// but Chromium 154 never reuses a renderer with a DevTools agent, and cmux opened a DevTools session
/// on every Chromium tab (document-start scripts, bindings, lifecycle events, evaluate, freeze, link
/// hint clicks), so no two tabs ever shared one. From fork API 29 those go through renderer paths
/// with no DevTools session (`CEFForkFeatures.rendererPaths`). Against a spy shim; the shipped fork
/// (API 24) keeps the DevTools path.
@MainActor @Suite(.serialized) struct CEFRendererPathsTests {
    @Test func theRendererPathsAddTheReuseSwitch() {
        func switches(_ paths: Bool) -> [String] {
            CEFSwitches.current(forkAPIVersion: 29, rendererPaths: paths, bundleIdentifier: "com.cmuxterm.app.next", environment: [:]).arguments
        }
        #expect(switches(true).contains(CEFSwitches.processReusePerRendererDevTools))
        #expect(!switches(false).contains(CEFSwitches.processReusePerRendererDevTools))
    }

    /// The same app runs on a CEF whose shim predates the renderer paths: it loads, and every tab
    /// keeps the DevTools path, also when the fork reports API 29.
    @Test func aShimWithoutTheRendererPathsStillLoadsAndKeepsTheDevToolsPath() async throws {
        Spy.reset(forkAPI: 29)
        Spy.exportsRendererPaths = false
        let library = try Spy.library()
        #expect(!library.hasRendererPaths)
        #expect(!CEFForkFeatures(library).rendererPaths)
        let rig = try Rig(forkAPI: 29, exports: false)
        defer { rig.close() }
        let tab = try rig.attachedTab()
        await rig.answeringDevTools { Spy.devToolsCalls.contains("Page.addScriptToEvaluateOnNewDocument") }
        #expect(Spy.devToolsCalls.contains("Page.addScriptToEvaluateOnNewDocument"), "\(Spy.devToolsCalls)")
        #expect(tab.setFrozen(true))
        #expect(Spy.devToolsCalls.contains("Page.setWebLifecycleState"))
        #expect(!tab.sendClick(x: 1, y: 1))
    }

    /// The fork's event numbers (cmux_cef_shim.h): PAGE_MESSAGE 49, EVALUATE_RESULT 50; 48 is FILE_DIALOG.
    @Test func theRendererPathEventsDecodeFromTheirNumbers() {
        #expect(CEFShimEvent(kind: 49, browser: 7, request: 0, a: 1, b: 0, s1: "cmuxMedia", s2: "{}")
                == .pageMessage(browser: 7, mainFrame: true, channel: "cmuxMedia", payload: "{}"))
        #expect(CEFShimEvent(kind: 50, browser: 7, request: 3, a: -2, b: 0, s1: "", s2: "")
                == .evaluateResult(token: 3, status: -2, value: ""))
        if case .pageMessage = CEFShimEvent(kind: 48, browser: 7, request: 0, a: 1, b: 0, s1: "cmuxMedia", s2: "{}") {
            Issue.record("FILE_DIALOG (48) decoded as a page message")
        }
    }

    /// Channel strings are untrusted (a compromised renderer can post anything).
    @Test func pageMessagesAreCheckedAsUntrustedData() {
        #expect(CEFPageMessage(channel: "cmuxMedia", payload: "{}", mainFrame: false)?.channel == .media)
        #expect(CEFPageMessage(channel: "evil", payload: "{}", mainFrame: true) == nil, "an unknown channel passed")
        #expect(CEFPageMessage(channel: "cmuxVerify", payload: "{}", mainFrame: false) == nil, "a child frame posted on a main-frame channel")
        let huge = String(repeating: "x", count: CEFPageMessage.maxPayloadBytes + 1)
        #expect(CEFPageMessage(channel: "cmuxMedia", payload: huge, mainFrame: true) == nil, "an oversized payload passed")
    }

    @Test func aTabOnForkAPI29OpensNoDevToolsSession() async throws {
        let rig = try Rig(forkAPI: 29)
        defer { rig.close() }
        let tab = try rig.attachedTab()
        await rig.settle()
        #expect(Spy.devToolsCalls.isEmpty, "the tab's own work opened a DevTools session: \(Spy.devToolsCalls)")
        // Its color scheme went as a web preference, not media emulation.
        #expect(!Spy.schemes.isEmpty)
        #expect(Spy.watched.allSatisfy { $0 == 0 }, "the tab turned on DevTools event delivery")

        // Evaluate goes through the renderer path, answered by EVALUATE_RESULT.
        let evaluation = Task { try await tab.evaluate("1 + 1", world: .page, gesture: .agent) }
        await rig.until { !Spy.evaluations.isEmpty }
        let call = try #require(Spy.evaluations.first)
        #expect(call.world == "" && call.gesture == 1)
        rig.runtime.handle(.evaluateResult(token: call.token, status: 1, value: "2"))
        #expect(try await evaluation.value == .number(2))
        // cmux's own script goes without a gesture.
        let probe = Task { try await tab.evaluate("1", world: .page, gesture: .cmux) }
        await rig.until { Spy.evaluations.count == 2 }
        let second = try #require(Spy.evaluations.last)
        #expect(second.gesture == 0)
        rig.runtime.handle(.evaluateResult(token: second.token, status: 1, value: "1"))
        _ = try await probe.value
        #expect(Spy.devToolsCalls.isEmpty)

        // Freeze through SetPageFrozen; a refused freeze (the tab still visible) reports false.
        Spy.freezeAnswer = 0
        #expect(tab.setFrozen(true) == false)
        Spy.freezeAnswer = 1
        #expect(tab.setFrozen(true))
        #expect(Spy.frozen == [1, 1])
        #expect(tab.sendClick(x: 10, y: 20))
        #expect(Spy.devToolsCalls.isEmpty)
    }

    @Test func aTabOnTheShippedForkKeepsTheDevToolsPath() async throws {
        let rig = try Rig(forkAPI: 24)
        defer { rig.close() }
        let tab = try rig.attachedTab()
        await rig.answeringDevTools { Spy.devToolsCalls.contains("Page.addScriptToEvaluateOnNewDocument") }
        #expect(tab.setFrozen(true))
        #expect(Spy.devToolsCalls.contains("Page.setWebLifecycleState"))
        #expect(Spy.frozen.isEmpty)
        #expect(!tab.sendClick(x: 1, y: 1))
    }

    @Test func aRendererInstallsEveryDocumentScriptOnceForEveryBrowser() throws {
        Spy.reset(forkAPI: 29)
        let refused = CEFDocumentScripts(post: .pageChannel).installInRenderer(try Spy.library())
        #expect(refused.isEmpty)
        #expect(Set(Spy.channels) == Set(CEFPageMessage.Channel.allCases.map(\.name)))
        // The page busy recorder reaches cross-origin frames (it reported nothing from them before).
        let recorder = CEFDocumentScripts.Script(world: "", body: BrowserPageBusy.recorderScript, allFrames: true, scope: .browserTabs)
        #expect(Spy.scripts.contains { $0.source == recorder.source && $0.world == "" && $0.allFrames == 1 })
        #expect(Spy.scripts.allSatisfy { !$0.source.contains("cmuxMedia(") }, "a page-channel script posts through a DevTools binding")
    }

    // MARK: cmux page tabs

    /// A cmux page's tab on the shipped fork attaches no browser-tab bridge: no media or verification script and no
    /// binding go over its DevTools session. Its first paint still reads lifecycle events, so the event watch is on.
    @Test func aPageTabOnTheShippedForkAttachesNoBrowserTabBridge() async throws {
        let rig = try Rig(forkAPI: 24)
        defer { rig.close() }
        _ = try rig.attachedTab(cmuxPage: true)
        await rig.answeringDevTools { Spy.devToolsCalls.contains("Page.getFrameTree") }
        await rig.settle()
        #expect(Spy.devToolsCalls.contains("Page.setLifecycleEventsEnabled"), "\(Spy.devToolsCalls)")
        #expect(!Spy.devToolsCalls.contains("Page.addScriptToEvaluateOnNewDocument"), "\(Spy.devToolsCalls)")
        #expect(!Spy.devToolsCalls.contains("Runtime.addBinding"), "\(Spy.devToolsCalls)")
        #expect(Spy.watched.last == 1, "the first paint bridge hears no lifecycle events")
    }

    /// From fork API 29 the media hub's post reaches a browser tab's bridge; a cmux page's tab drops it (its renderer
    /// runs no browser-tab script, so the post is not cmux's) and opens no DevTools session.
    @Test(arguments: [false, true]) func aMediaPostReachesOnlyABrowserTab(cmuxPage: Bool) async throws {
        let rig = try Rig(forkAPI: 29)
        defer { rig.close() }
        let tab = try rig.attachedTab(cmuxPage: cmuxPage)
        await rig.settle()
        #expect(Spy.devToolsCalls.isEmpty, "\(Spy.devToolsCalls)")
        let post = try #require(CEFPageMessage(channel: "cmuxMedia", payload: #"{"frame":"f1","report":{"title":"Song","playing":true}}"#,
                                               mainFrame: true))
        tab.agentRelay.pageMessage(post)
        #expect((tab.state.media != nil) == !cmuxPage, "media \(String(describing: tab.state.media))")
    }

    /// A cmux page's page host post reaches its tab's taker in the event's turn, split into the
    /// relay's sender stamp and the page's text; a post with no stamp is dropped, and a browser tab, whose renderer
    /// runs no page host relay, drops every one. Only a cmux page's tab names the page channel event.
    @Test(arguments: [false, true]) func aPageHostPostReachesOnlyACmuxPageTab(cmuxPage: Bool) async throws {
        let rig = try Rig(forkAPI: 29)
        defer { rig.close() }
        let tab = try rig.attachedTab(cmuxPage: cmuxPage)
        await rig.settle()
        var taken: [String] = []
        tab.agentRelay.onPageHostPost = { text, sender in taken.append(sender.absoluteString + " " + text) }
        let text = #"{"name":"cmuxPage","seq":1,"body":{}}"#
        for payload in ["cmux-page://agent/index.html\n" + text, text] {
            tab.agentRelay.pageMessage(try #require(CEFPageMessage(channel: CEFDocumentScripts.pageHostChannel, payload: payload, mainFrame: true)))
        }
        #expect(taken == (cmuxPage ? ["cmux-page://agent/index.html " + text] : []))
        #expect(tab.agentRelay.pageHostEvent == CEFDocumentScripts.pageHostEvent)
        #expect(Spy.devToolsCalls.isEmpty, "\(Spy.devToolsCalls)")
    }

    /// Before fork API 29 the runtime installs no page channel: a cmux page posts on its DevTools binding.
    @Test func aTabOnTheShippedForkHasNoPageHostEvent() throws {
        let rig = try Rig(forkAPI: 24)
        defer { rig.close() }
        let tab = try rig.attachedTab(cmuxPage: true)
        #expect(tab.agentRelay.pageHostEvent == nil)
    }

    /// The page host channel takes a page call's full size from the main frame only.
    @Test func pageHostPostsAreCheckedAsUntrustedData() {
        let channel = CEFDocumentScripts.pageHostChannel
        #expect(CEFPageMessage(channel: channel, payload: "{}", mainFrame: false) == nil, "a child frame posted to the page host")
        let call = String(repeating: "x", count: CEFPageMessage.maxPayloadBytes + 1)
        #expect(CEFPageMessage(channel: channel, payload: call, mainFrame: true)?.channel == .pageHost, "a large page call was refused")
        let huge = String(repeating: "x", count: CEFPageMessage.maxPageHostPayloadBytes + 1)
        #expect(CEFPageMessage(channel: channel, payload: huge, mainFrame: true) == nil, "an oversized page call passed")
    }

    /// The spare window's about:blank placeholder is never shown, so Chromium never learned it was hidden and ran
    /// its frames and timers at idle (visibilityState "visible", rAF ~98/s; fleet probe 4e065838, macOS 27). Its
    /// page is frozen through DevTools as soon as its browser exists, on every fork: the renderer-path freeze
    /// refuses a page Chromium counts visible. Another host's tab is not.
    @Test(arguments: [Int32(24), 29]) func theSparePlaceholderIsFrozenWhenItsBrowserExists(forkAPI: Int32) throws {
        let rig = try Rig(forkAPI: forkAPI)
        defer { rig.close() }
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: "spare-\(UUID().uuidString)"), profile: .default), runtime: rig.runtime)
        let blank = CEFTab(id: .random(), profile: .default, host: host, runtime: rig.runtime)
        host.placeholder = blank
        host.quietsPlaceholder = true
        host.add(blank)
        host.ensureCreated(blank)
        let request = try #require(rig.runtime.pendingWindows.keys.first)
        Spy.devToolsSent = []
        rig.runtime.handle(.afterCreated(browser: 7, request: request, window: 1))
        try #require(blank.browserID == 7)
        #expect(Spy.devToolsCalls.filter { $0 == "Page.setWebLifecycleState" }.count == 1, "\(Spy.devToolsCalls)")
        #expect(Spy.frozen.isEmpty, "the renderer-path freeze refuses a page Chromium counts visible")
    }

    @Test func aPlaceholderOfAHostThatDoesNotFreezeItStaysAwake() throws {
        let rig = try Rig(forkAPI: 29)
        defer { rig.close() }
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: rig.runtime)
        let blank = CEFTab(id: .random(), profile: .default, host: host, runtime: rig.runtime)
        host.placeholder = blank  // a popup host's placeholder: it closes when the popup moves in
        host.add(blank)
        host.ensureCreated(blank)
        let request = try #require(rig.runtime.pendingWindows.keys.first)
        Spy.devToolsSent = []
        rig.runtime.handle(.afterCreated(browser: 7, request: request, window: 1))
        #expect(!Spy.devToolsCalls.contains("Page.setWebLifecycleState"), "\(Spy.devToolsCalls)")
    }

    // MARK: Cookies (on this file's spy shim)

    /// `browser.page.cookies.list` on a Chromium tab: the `Network.getAllCookies` reply, a whole jar far above the main
    /// thread's JSON gate, is parsed on the `.cpu` lane it is given, never on the main thread, and every field comes
    /// through.
    @Test func aTabsCookieJarIsParsedOnTheCPULane() async throws {
        let rig = try Rig(forkAPI: 29)
        defer { rig.close() }
        let tab = try rig.attachedTab()
        await rig.settle()
        // One .cpu slot: the sentinel item below runs after the parse item reported its run.
        let lanes = OSAllocatedUnfairLock<[BlockingLane]>(initialState: [])
        let work = BackgroundWork(cpuWidth: 1, label: "test.cef-cookies", onRan: { lane, _, _, _ in lanes.withLock { $0.append(lane) } })
        let filler = (0..<2_000).map { #"{"name":"n\#($0)","value":"v","domain":"filler.test","path":"/","session":true}"# }
        let jar = #"{"cookies":[{"name":"sid","value":"abc","domain":".example.com","path":"/app","expires":1893456000,"#
            + #""session":false,"secure":true,"httpOnly":true},"# + filler.joined(separator: ",") + "]}"
        try #require(jar.utf8.count > BlockingKind.cpuIntensiveJSONBytes)
        let table = BlockingViolationTable(mode: .record)

        let listed = BlockingViolationTable.$scoped.withValue(table) { Task { try await tab.cookies(on: work) } }
        await rig.until { Spy.devToolsCalls == ["Network.getAllCookies"] }
        let message = try #require(Spy.unanswered.last)
        rig.runtime.handle(.devToolsResult(browser: 7, messageID: message, success: true, json: jar))
        let cookies = try await listed.value
        try await work.run(.userVisible, mayBlock: .cpu) {}
        await table.flush()

        #expect(lanes.withLock { $0.first } == .cpu, "the jar was not parsed on the .cpu lane")
        #expect(table.sites.filter { $0.kind == .cpuIntensive }.isEmpty, "the jar was parsed on the main thread: \(table.sites)")
        #expect(cookies.count == 2_001)
        let sid = try #require(cookies.first)
        #expect(sid == BrowserCookie(name: "sid", value: "abc", domain: ".example.com", path: "/app",
                                     expires: Date(timeIntervalSince1970: 1_893_456_000), secure: true, httpOnly: true))
        #expect(cookies.last?.expires == nil, "a session cookie has no expiry")
        await work.shutdown()
    }

    // MARK: Surface copy

    /// From fork API 40 a tab's picture is the fork's surface copy, with no DevTools call: the request leaves in the
    /// caller's turn (before a hide that follows it), sized to whole pixels, and the CMUX_SHIM_REPLY under its reply
    /// id brings the PNG and its size; a reply with no size is no picture.
    @Test func aTabOnForkAPI40CopiesItsSurfaceWithNoDevToolsCall() async throws {
        let rig = try Rig(forkAPI: CEFForkFeatures.surfaceCopyForkAPI)
        defer { rig.close() }
        let tab = try rig.attachedTab()
        await rig.settle()
        #expect(tab.copiesSurface)
        var copies: [CEFSurfaceCopy?] = []
        tab.copySurface(maxPixelSize: CGSize(width: 640.7, height: 400)) { copies.append($0) }
        let call = try #require(Spy.copies.first, "the copy did not leave in the caller's turn")
        #expect(call == Spy.Copy(browser: 7, reply: call.reply, width: 640, height: 400, format: CEFSurfaceCopyFormat.png.rawValue))
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        rig.runtime.handle(.reply(browser: 7, id: call.reply, value: 640 | (Int64(400) << 32), json: png.base64EncodedString()))
        await rig.until { !copies.isEmpty }
        #expect(copies == [CEFSurfaceCopy(base64: png.base64EncodedString(), pixelSize: CGSize(width: 640, height: 400))],
                "the copy is passed on in base64: the page host decodes it off the main thread")

        tab.copySurface(maxPixelSize: CGSize(width: 10, height: 10)) { copies.append($0) }
        let empty = try #require(Spy.copies.last)
        rig.runtime.handle(.reply(browser: 7, id: empty.reply, value: 0, json: ""))
        await rig.until { copies.count == 2 }
        #expect(copies.last == .some(nil), "a reply with no size gave a picture")

        // A size below one pixel is not sent; a start the shim refuses is no picture.
        tab.copySurface(maxPixelSize: CGSize(width: 0.5, height: 100)) { copies.append($0) }
        #expect(copies.count == 3 && copies.last == .some(nil) && Spy.copies.count == 2, "a size below one pixel was sent")
        Spy.copyStart = 0
        tab.copySurface(maxPixelSize: CGSize(width: 100, height: 100)) { copies.append($0) }
        await rig.until { copies.count == 4 }
        #expect(copies.last == .some(nil) && Spy.copies.count == 3)
        #expect(Spy.devToolsCalls.isEmpty, "\(Spy.devToolsCalls)")
        #expect(rig.runtime.surfaceCopies.count == 0, "an answered copy still waits")

        // A copy still waiting when its browser closes gets no picture.
        Spy.copyStart = 1
        tab.copySurface(maxPixelSize: CGSize(width: 100, height: 100)) { copies.append($0) }
        #expect(rig.runtime.surfaceCopies.count == 1)
        rig.runtime.handle(.beforeClose(browser: 7))
        #expect(copies.count == 5 && copies.last == .some(nil))
        #expect(rig.runtime.surfaceCopies.count == 0)
    }

    /// A menu's Copy is a page script sent with the person's gesture and no waiter: `tabEvaluate` on fork API 29 (no
    /// DevTools session), a `Runtime.evaluate` before it.
    @Test(arguments: [Int32(24), 29]) func aPerformedScriptLeavesWithNoWaiter(forkAPI: Int32) async throws {
        let rig = try Rig(forkAPI: forkAPI)
        defer { rig.close() }
        let tab = try rig.attachedTab()
        if forkAPI < 29 { await rig.answeringDevTools { Spy.devToolsCalls.contains("Page.addScriptToEvaluateOnNewDocument") } }
        await rig.settle()
        Spy.devToolsSent = []
        #expect(tab.perform("document.execCommand('copy')", gesture: .agent))
        if forkAPI >= 29 {
            let call = try #require(Spy.evaluations.last)
            #expect(call.world == "" && call.gesture == 1)
            #expect(Spy.devToolsCalls.isEmpty, "\(Spy.devToolsCalls)")
            // Its answer finds no caller and changes nothing.
            rig.runtime.handle(.evaluateResult(token: call.token, status: 1, value: "true"))
        } else {
            #expect(Spy.devToolsCalls == ["Runtime.evaluate"])
        }
    }

    /// From fork API 40 a scripted hover is the fork's native mouse move (`SendMouseMoveEvent`, no button), with no
    /// DevTools call; below it, or with the export missing, the tab says no and the caller uses DevTools input.
    @Test(arguments: [CEFForkFeatures.mouseMoveForkAPI - 1, CEFForkFeatures.mouseMoveForkAPI])
    func aTabMovesTheMouseNativelyFromForkAPI40(forkAPI: Int32) async throws {
        let rig = try Rig(forkAPI: forkAPI)
        defer { rig.close() }
        let tab = try rig.attachedTab()
        await rig.settle()
        Spy.devToolsSent = []
        let native = forkAPI >= CEFForkFeatures.mouseMoveForkAPI
        #expect(tab.sendMouseMove(x: 12.5, y: 30) == native)
        #expect(Spy.mouseMoves == (native ? [Spy.Move(browser: 7, x: 12.5, y: 30, modifiers: 0)] : []))
        #expect(Spy.devToolsCalls.isEmpty, "\(Spy.devToolsCalls)")
        rig.runtime.handle(.beforeClose(browser: 7))
        #expect(!tab.sendMouseMove(x: 1, y: 1), "a closed tab moved the mouse")
    }

    /// Below fork API 40 there is no surface copy: no picture at once, no shim call and no DevTools.
    @Test func aForkBeforeTheSurfaceCopyAnswersNoPictureAtOnce() async throws {
        let rig = try Rig(forkAPI: CEFForkFeatures.surfaceCopyForkAPI - 1)
        defer { rig.close() }
        let tab = try rig.attachedTab()
        await rig.settle()
        #expect(!tab.copiesSurface)
        var answers: [CEFSurfaceCopy?] = []
        tab.copySurface(maxPixelSize: CGSize(width: 100, height: 100)) { answers.append($0) }
        #expect(answers == [nil])
        #expect(Spy.copies.isEmpty && Spy.devToolsCalls.isEmpty, "\(Spy.devToolsCalls)")
    }

    /// A bridge sends the rest of its batch after the runtime's last owner is gone.
    ///
    /// `CEFTab.runtime` is `unowned` and nothing in the tab/host island retains the runtime, so the
    /// runtime can be released while its tabs live on. `CEFMediaBridge.run` and
    /// `CEFVerificationBridge.run` send a batch of calls from one `Task` that captured `[weak tab]`
    /// and re-read `tab.runtime` each time round: the in-flight `runtime.devTools(...)` held the
    /// runtime, but nothing held it between two calls of the batch, so once the last owner went the
    /// next read found a destroyed object and trapped in `swift_abortRetainUnowned`.
    ///
    /// That trap aborts the process instead of failing one test, so before the fix this reads as a
    /// crash and not as a failed expectation: on CI it killed the swift test helper part-way
    /// through and every test after it went unreported (cmux#25530).
    ///
    /// Fork API 24 is the DevTools path; from 29 `CEFAgentRelay.browserAttached` does not attach
    /// these bridges at all.
    /// This test's own browser id. Every other test in the suite attaches browser 7, so a call
    /// recorded against this one can only have come from this test's bridges -- which is what lets
    /// the progress assertion below read the static `Spy` without depending on what ran before it.
    private static let lateBrowser: Int32 = 77

    /// The methods only the two bridges this PR fixes send, and only *after* the first call of
    /// their batch. API 24 also attaches `CEFFirstPaintBridge`, which is already safe (it takes a
    /// strong `let runtime = tab.runtime` before its Task) and sends `Page.enable`,
    /// `Page.setLifecycleEventsEnabled` and `Page.getFrameTree`. Counting any call to this
    /// browser would let one of those satisfy the progress assertion while the batches this test
    /// exists for never resumed, so the oracle is narrowed to methods first paint never sends.
    private static let lateBatchMethods: Set<String> = ["Runtime.addBinding", "Page.addScriptToEvaluateOnNewDocument"]

    @Test func aBridgeSendsTheRestOfItsBatchAfterItsRuntimesLastOwnerIsGone() async throws {
        weak var runtime: CEFRuntime?
        var tab: CEFTab?
        var parked: [Int32] = []
        var sentBeforeRelease = 0
        do {
            let rig = try Rig(forkAPI: 24)
            runtime = rig.runtime
            tab = try rig.attachedTab(browser: Self.lateBrowser)
            // Nothing answers the spy's DevTools calls, so each bridge Task parks on the first call
            // of its batch, with the rest still to send.
            await rig.settle()
            parked = Spy.unanswered
            sentBeforeRelease = Self.lateBatchCalls
            rig.close()
        }
        try #require(!parked.isEmpty, "no DevTools call is parked, so the rest of this proves nothing")
        try #require(Self.callsToLateBrowser > 0, "no bridge call went to this test's browser, so its batches never started")

        // The rig was the runtime's only owner. The tab lives on, as a pane's tab does while the
        // runtime is torn down. Answering the parked calls lets each Task go round to the next call
        // of its batch: the read that trapped. The answer takes its own reference inside
        // `answerParked`, so the runtime is unowned again before the yield the Task resumes on --
        // holding one here would be what keeps it alive and would prove nothing.
        func answerParked() {
            guard let runtime else { return }
            for id in Spy.unanswered {
                runtime.handle(.devToolsResult(browser: Self.lateBrowser, messageID: id, success: true, json: "{}"))
            }
            Spy.unanswered = []
        }
        // Drains until one of the two fixed bridges has sent a later call of its batch, rather than
        // until the queue happens to be empty: `answerParked` clearing `Spy.unanswered` is not
        // progress, and a loop that stopped there would pass without ever reaching the read that
        // trapped.
        for _ in 0..<500 where Self.lateBatchCalls == sentBeforeRelease {
            answerParked()
            await Task.yield()
        }

        // The progress oracle. One of the two fixed bridges issuing a later call of its batch *is*
        // the read that trapped, so this fails rather than passes vacuously if the batch never
        // resumed -- if the drain loop times out, if the weak runtime is already nil, or if a
        // future change stops parking mid-batch. Two filters make it specific: the browser, so a
        // leaked task from an earlier test in this serialized suite cannot satisfy it, and the
        // method, so the already-safe first-paint bridge attached alongside cannot either.
        #expect(Self.lateBatchCalls > sentBeforeRelease,
                "neither fixed bridge sent a later call of its batch after its runtime's last owner went, so this test never exercised the unowned read")

        // Surviving to here is the other half of the assertion, and the half an expectation cannot
        // express: before the fix the read traps in `swift_abortRetainUnowned`, which aborts the
        // whole process instead of failing a test (the run that proved it exited 1 on signal 6 with
        // `closure #1 in CEFMediaBridge.run` in frame 6; the same suite with the fix exits 0).
        withExtendedLifetime(tab) {}
    }

    /// Every DevTools call recorded against this test's browser.
    private static var callsToLateBrowser: Int {
        Spy.devToolsSent.filter { $0.browser == lateBrowser }.count
    }

    /// The calls to this test's browser that only `CEFMediaBridge.run` or
    /// `CEFVerificationBridge.run` can have sent, past the first call of their batch.
    private static var lateBatchCalls: Int {
        Spy.devToolsSent
            .filter { $0.browser == lateBrowser && lateBatchMethods.contains($0.method) }
            .count
    }

    // MARK: Rig

    @MainActor final class Rig {
        let runtime: CEFRuntime
        let root: URL

        init(forkAPI: Int32, exports: Bool = true) throws {
            Spy.reset(forkAPI: forkAPI)
            Spy.exportsRendererPaths = exports
            root = FileManager.default.temporaryDirectory.appending(path: "cef-renderer-paths-\(UUID().uuidString)", directoryHint: .isDirectory)
            runtime = CEFRuntime.spy(shim: try Spy.library(), storage: CEFProfileStorage(root: root))
        }

        /// A tab whose browser exists (AFTER_CREATED), 7 unless a test needs its own id; with `cmuxPage`, a cmux
        /// page's tab (`CEFEngine.makePagesTab`).
        func attachedTab(browser: Int32 = 7, cmuxPage: Bool = false) throws -> CEFTab {
            let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
            let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            tab.agentRelay.servesCmuxPage = cmuxPage
            host.add(tab)
            host.ensureCreated(tab)
            let request = try #require(runtime.pendingWindows.keys.first)
            runtime.handle(.afterCreated(browser: browser, request: request, window: 1))
            try #require(tab.browserID == browser)
            return tab
        }

        /// Lets the tab's attach tasks run.
        func settle() async {
            for _ in 0..<50 { await Task.yield() }
        }

        func until(_ condition: () -> Bool) async {
            for _ in 0..<500 where !condition() { await Task.yield() }
        }

        /// Answers every DevTools call the tab sent (as Chromium's DEVTOOLS_RESULT would) until `condition`.
        func answeringDevTools(_ condition: () -> Bool) async {
            for _ in 0..<500 where !condition() {
                for id in Spy.unanswered { runtime.handle(.devToolsResult(browser: 7, messageID: id, success: true, json: "{}")) }
                Spy.unanswered = []
                await Task.yield()
            }
        }

        func close() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

/// The shim's renderer-path calls and every DevTools method sent, recorded.
private nonisolated enum Spy {
    struct Evaluation { let token: Int32; let world: String; let gesture: Int32 }
    struct Script { let world: String; let source: String; let allFrames: Int32 }
    nonisolated(unsafe) static var forkAPI: Int32 = 0
    /// Every DevTools call sent, with the browser it went to. One array rather than two, so a
    /// test that clears the methods cannot leave the browsers behind and misalign them.
    nonisolated(unsafe) static var devToolsSent: [(method: String, browser: Int32)] = []
    /// The methods of `devToolsSent`, which is what most tests here assert on.
    static var devToolsCalls: [String] { devToolsSent.map(\.method) }
    nonisolated(unsafe) static var watched: [Int32] = []
    nonisolated(unsafe) static var evaluations: [Evaluation] = []
    nonisolated(unsafe) static var frozen: [Int32] = []
    nonisolated(unsafe) static var freezeAnswer: Int32 = 1
    nonisolated(unsafe) static var channels: [String] = []
    nonisolated(unsafe) static var schemes: [Int32] = []
    nonisolated(unsafe) static var scripts: [Script] = []
    nonisolated(unsafe) static var nextMessage: Int32 = 1
    nonisolated(unsafe) static var unanswered: [Int32] = []
    /// False: the shim predates fork API 29 and has none of its exports.
    nonisolated(unsafe) static var exportsRendererPaths = true
    /// One `cmux_shim_tab_copy_surface` call: browser, reply id, max width, max height, format.
    struct Copy: Equatable { let browser: Int32; let reply: Int32; let width: Int32; let height: Int32; let format: Int32 }
    nonisolated(unsafe) static var copies: [Copy] = []
    /// What `cmux_shim_tab_copy_surface` returns (1 started).
    nonisolated(unsafe) static var copyStart: Int32 = 1
    /// One `cmux_shim_tab_send_mouse_move` call: browser, x, y (view points), modifiers.
    struct Move: Equatable { let browser: Int32; let x: Double; let y: Double; let modifiers: Int32 }
    nonisolated(unsafe) static var mouseMoves: [Move] = []
    static let rendererPathSymbols: Set<String> = ["cmux_shim_add_document_script", "cmux_shim_add_page_channel", "cmux_shim_tab_evaluate",
                                                    "cmux_shim_tab_set_frozen", "cmux_shim_tab_send_click", "cmux_shim_tab_set_color_scheme"]

    static func reset(forkAPI api: Int32) {
        forkAPI = api
        devToolsSent = []
        watched = []
        evaluations = []
        frozen = []
        freezeAnswer = 1
        channels = []
        schemes = []
        scripts = []
        nextMessage = 1
        unanswered = []
        exportsRendererPaths = true
        copies = []
        copyStart = 1
        mouseMoves = []
    }

    static func library() throws -> CEFShimLibrary {
        let version: @convention(c) () -> Int32 = { Spy.forkAPI }
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let devToolsCall: @convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { browser, method, _ in
            Spy.devToolsSent.append((method.map { String(cString: $0) } ?? "", browser))
            Spy.nextMessage += 1
            Spy.unanswered.append(Spy.nextMessage)
            return Spy.nextMessage
        }
        let watch: @convention(c) (Int32, Int32) -> Void = { _, on in Spy.watched.append(on) }
        let evaluate: @convention(c) (Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32) -> Int32 = { _, token, world, _, gesture in
            Spy.evaluations.append(Evaluation(token: token, world: world.map { String(cString: $0) } ?? "", gesture: gesture))
            return 1
        }
        let freeze: @convention(c) (Int32, Int32) -> Int32 = { _, frozen in Spy.frozen.append(frozen); return Spy.freezeAnswer }
        let click: @convention(c) (Int32, Double, Double, Int32, Int32, Int32) -> Int32 = { _, _, _, _, _, _ in 1 }
        let scheme: @convention(c) (Int32, Int32) -> Int32 = { _, value in Spy.schemes.append(value); return 1 }
        let channel: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, name in
            Spy.channels.append(name.map { String(cString: $0) } ?? "")
            return 1
        }
        let script: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32, Int32) -> Int32 = { world, source, all, _ in
            Spy.scripts.append(Script(world: world.map { String(cString: $0) } ?? "", source: source.map { String(cString: $0) } ?? "", allFrames: all))
            return 1
        }
        let copy: @convention(c) (Int32, Int32, Int32, Int32, Int32, Int32) -> Int32 = { browser, reply, width, height, format, _ in
            Spy.copies.append(Copy(browser: browser, reply: reply, width: width, height: height, format: format))
            return Spy.copyStart
        }
        let mouseMove: @convention(c) (Int32, Double, Double, Int32) -> Int32 = { browser, x, y, modifiers in
            Spy.mouseMoves.append(Move(browser: browser, x: x, y: y, modifiers: modifiers))
            return 1
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            if !Spy.exportsRendererPaths, Spy.rendererPathSymbols.contains(name) { return nil }
            return switch name {
            case "cmux_shim_fork_api_version": unsafeBitCast(version, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_devtools_call": unsafeBitCast(devToolsCall, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_devtools_watch_events": unsafeBitCast(watch, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_tab_evaluate": unsafeBitCast(evaluate, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_tab_set_frozen": unsafeBitCast(freeze, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_tab_send_click": unsafeBitCast(click, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_tab_set_color_scheme": unsafeBitCast(scheme, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_add_page_channel": unsafeBitCast(channel, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_add_document_script": unsafeBitCast(script, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_tab_copy_surface": unsafeBitCast(copy, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_tab_send_mouse_move": unsafeBitCast(mouseMove, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
