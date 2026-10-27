@testable import CmuxNextBrowser
import Foundation
import Testing

/// Task 027 of plans/cmux-next/chrome-parity/p01-process.md: the downloads, print, certificate,
/// DevTools relay and bookmarks sites keep one form for both backends. A post's answer is never
/// read (in host mode it is a stand-in), and an async op's answer comes as the call's own in
/// process and as the host's REPLY in host mode, delivered here through the C callback that
/// `cmux_remote_shim_set_reply` was given (the path the host's frames take).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct CEFHostModeSitesTests {
    // MARK: Posts: the answer is not read

    /// `chrome::Print` returns nothing: a page with a browser prints whatever the op answers.
    @Test func printIsSentOneWay() throws {
        SitesSpy.reset()
        let runtime = try SitesHarness.inProcessRuntime()
        let tab = SitesHarness.attachedTab(runtime)
        SitesSpy.calls = []

        #expect(BrowserPagePrint(tab).run(), "the stand-in 0 was read as a gone browser")
        #expect(SitesSpy.calls == ["print 7"])

        let unattached = HostRepliesHarness.tab(in: HostRepliesHarness.pane(runtime, profile: .default).0)
        #expect(!BrowserPagePrint(unattached).run())
        #expect(SitesSpy.calls == ["print 7"], "a tab without a browser sent a print")
    }

    /// The certificate answer goes before the load, and the load goes whatever the answer was.
    @Test func certificateProceedIsSentBeforeTheLoad() throws {
        SitesSpy.reset()
        let runtime = try SitesHarness.inProcessRuntime()
        let tab = SitesHarness.attachedTab(runtime)
        let url = try #require(URL(string: "https://192.168.1.4/page"))
        let id = tab.makeNavigationID()
        tab.machine.apply(.started(id, url: url))
        tab.machine.apply(.failed(id, BrowserLoadError(domain: ChromiumNetError.domain, code: -202, message: "", failingURL: url)))
        SitesSpy.calls = []

        ChromiumNetError.proceed(on: tab)

        #expect(SitesSpy.calls == ["certificate 7 192.168.1.4 -202 0", "load 7 https://192.168.1.4/page"])
    }

    /// `DownloadManager::DownloadUrl` returns nothing: a download sent to a live browser is true,
    /// and only the local checks (scheme, liveness) refuse one.
    @Test func aDownloadIsTrueOnceSent() throws {
        var starts: [String] = []
        let downloads = CEFDownloads {
            CEFDownloadShim(start: { browser, url in starts.append("\(browser) \(url)"); return browser == 3 },
                            answer: { _, _ in }, control: { _, _ in })
        }

        #expect(downloads.download("https://a.test/file.zip", browser: 3))
        #expect(downloads.save(try #require(URL(string: "https://a.test/b.zip")), to: URL(filePath: "/tmp/b.zip"), browser: 3))
        #expect(!downloads.download("file:///etc/hosts", browser: 3))
        #expect(!downloads.download("https://a.test/gone.zip", browser: 4))
        #expect(starts == ["3 https://a.test/file.zip", "3 https://a.test/b.zip", "4 https://a.test/gone.zip"])
    }

    /// Retry of a download whose tab closed: the runtime knows the browser is gone, so nothing is
    /// sent and Retry is false (the Downloads list keeps the row, `BrowserDownloadList.retry`), in
    /// both backends. Before, the post's stand-in made it true and the row was dropped.
    @Test func retryOfADownloadWhoseTabClosedIsFalseAndSendsNothing() throws {
        SitesSpy.reset()
        let runtime = try SitesHarness.inProcessRuntime()
        let tab = SitesHarness.attachedTab(runtime)
        runtime.tabsByBrowser[7] = tab
        let downloads = CEFDownloads.forRuntime(runtime)
        let folder = FileManager.default.temporaryDirectory.appending(path: "cef-sites-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        downloads.directory = { folder }
        var delivered: [BrowserDownload] = []
        downloads.deliver = { _, item in delivered.append(item) }
        let url = "https://a.test/f.zip"
        SitesSpy.calls = []

        #expect(downloads.download(url, browser: 7))
        downloads.handle(.started(id: 1, browser: 7, url: url, suggestedName: "f.zip", totalBytes: nil))
        let item = try #require(delivered.first)
        item.cancel()
        #expect(item.canRetry)

        runtime.tabsByBrowser[7] = nil
        #expect(!item.retry(), "Retry of a download whose tab closed reported a start")
        #expect(SitesSpy.calls == ["download 7 \(url)"], "a start went to a gone browser")

        runtime.tabsByBrowser[7] = tab
        #expect(item.retry())
        #expect(SitesSpy.calls == ["download 7 \(url)", "download 7 \(url)"])
    }

    // MARK: DevTools relay: a refusal comes back on the stream

    @Test func inProcessARefusedRelayMessageComesBackAsAnErrorReply() throws {
        SitesSpy.reset()
        let runtime = try SitesHarness.inProcessRuntime()
        let tab = SitesHarness.attachedTab(runtime)
        var stream: [String] = []
        tab.agentRelay.set(onMessage: { stream.append($0) }, onEnd: {})
        let message = #"{"id":1073741825,"method":"Page.enable","sessionId":"S1"}"#

        SitesSpy.devToolsSendAnswer = 1
        #expect(tab.agentRelay.send(message) == .sent)
        #expect(stream.isEmpty)

        SitesSpy.devToolsSendAnswer = -1
        #expect(tab.agentRelay.send(message) == .sent)
        let reply = try SitesHarness.object(try #require(stream.last))
        #expect(reply["id"] as? Int == 1_073_741_825)
        #expect(reply["sessionId"] as? String == "S1")
        #expect((reply["error"] as? [String: Any])?["message"] as? String == "Chromium refused the message")
        #expect(SitesSpy.sends == [message, message])
    }

    @Test func aRelayMessageWithoutARawIDIsRefusedBeforeItIsSent() throws {
        SitesSpy.reset()
        let runtime = try SitesHarness.inProcessRuntime()
        let tab = SitesHarness.attachedTab(runtime)

        #expect(tab.agentRelay.send(#"{"id":5,"method":"Page.enable"}"#) == .refused)
        #expect(tab.agentRelay.send("not json") == .refused)
        #expect(SitesSpy.sends.isEmpty)
    }

    @Test func hostModeTheRelaysAnswerIsTheHostsReply() async throws {
        SitesSpy.reset()
        let (runtime, host) = try await SitesHarness.hostRuntime()
        let tab = SitesHarness.attachedTab(runtime)
        var stream: [String] = []
        tab.agentRelay.set(onMessage: { stream.append($0) }, onEnd: {})
        let message = #"{"id":1073741830,"method":"Runtime.enable"}"#
        let waiting = host.replies.count

        #expect(tab.agentRelay.send(message) == .sent)
        #expect(stream.isEmpty, "the relay answered before the host did")
        #expect(host.replies.count == waiting + 1)
        try SitesHarness.deliver(SitesSpy.lastToken, CEFReplyWaitersTests.int32(1))
        #expect(stream.isEmpty, "an accepted message got an error reply")

        #expect(tab.agentRelay.send(message) == .sent)
        try SitesHarness.deliver(SitesSpy.lastToken, CEFReplyWaitersTests.int32(0))
        let reply = try SitesHarness.object(try #require(stream.last))
        #expect(reply["id"] as? Int == 1_073_741_830)
        #expect(reply["sessionId"] == nil)
        #expect((reply["error"] as? [String: Any])?["message"] as? String == "the tab's page has no browser")
        #expect(host.replies.count == waiting)
    }

    /// A slow host may still have sent the message: its deadline makes up no error, so Chromium's
    /// real reply, when it comes, is the only answer the agent gets (`DevToolsSession` never answers
    /// for a message in flight). The relay's close answers what stays pending.
    @Test func hostModeARelayMessagePastItsDeadlineGetsNoMadeUpError() async throws {
        SitesSpy.reset()
        let (runtime, _) = try await SitesHarness.hostRuntime()
        let rig = HostRepliesHarness.deadlines(of: runtime)
        let tab = SitesHarness.attachedTab(runtime)
        var stream: [String] = []
        tab.agentRelay.set(onMessage: { stream.append($0) }, onEnd: {})

        #expect(tab.agentRelay.send(#"{"id":1073741831,"method":"Page.enable"}"#) == .sent)
        rig.advance(by: CEFRuntime.siteReplyTimeout + .seconds(2))

        #expect(stream.isEmpty, "a message the host may still answer got an error reply")
    }

    /// The host exited before it answered: no real reply can come, so the message fails on the stream.
    @Test func hostModeARelayMessageWhoseHostExitedFailsOnTheStream() async throws {
        SitesSpy.reset()
        let (runtime, _) = try await SitesHarness.hostRuntime()
        let tab = SitesHarness.attachedTab(runtime)
        var stream: [String] = []
        tab.agentRelay.set(onMessage: { stream.append($0) }, onEnd: {})

        #expect(tab.agentRelay.send(#"{"id":1073741832,"method":"Page.enable","sessionId":"S2"}"#) == .sent)
        #expect(stream.isEmpty)
        runtime.hostGone()

        let reply = try SitesHarness.object(try #require(stream.last))
        #expect(reply["id"] as? Int == 1_073_741_832)
        #expect(reply["sessionId"] as? String == "S2")
        #expect((reply["error"] as? [String: Any])?["message"] as? String == "the Chromium Host exited")
    }

    /// One CDP error shape for both relays (`CDPRawIDMap` answers the host's commands with it).
    @Test func theErrorReplyKeepsTheIdAndSession() throws {
        let reply = try SitesHarness.object(try #require(CEFDevToolsRawMessage.errorReply(id: 1_073_741_833, sessionID: "S3", text: "t")))
        #expect(reply["id"] as? Int == 1_073_741_833)
        #expect(reply["sessionId"] as? String == "S3")
        #expect((reply["error"] as? [String: Any])?["code"] as? Int == -32000)
        #expect(CEFDevToolsRawMessage.sessionID(in: #"{"id":1,"method":"Page.enable","sessionId":"S4"}"#) == "S4")
        #expect(CEFDevToolsRawMessage.sessionID(in: #"{"id":1,"method":"Page.enable"}"#) == nil)
    }

    // MARK: Bookmarks: a refusal forgets the store when it is known

    @Test func inProcessARefusedBookmarkSyncForgetsTheStore() throws {
        SitesSpy.reset()
        let runtime = try SitesHarness.inProcessRuntime()
        runtime.state = .ready
        let bridge = CEFBookmarkBridge(runtime: runtime)
        let (profile, store) = SitesHarness.store(in: bridge)
        var failures: [CEFBookmarkBridge.SyncFailure] = []

        SitesSpy.bookmarksAnswer = 0
        bridge.sync(store: store, treeJSON: #"{"nodes":[]}"#) { failures.append($0) }
        #expect(failures.isEmpty)
        #expect(bridge.stores[profile] == [store], "a model that is not loaded yet forgot its store")

        SitesSpy.bookmarksAnswer = -1
        bridge.sync(store: store, treeJSON: #"{"nodes":[]}"#) { failures.append($0) }
        #expect(failures == [.refused])
        #expect(bridge.stores[profile]?.isEmpty == true)
        #expect(SitesSpy.syncs == [store, store])
    }

    @Test func hostModeABookmarkSyncIsDecidedByTheHostsReply() async throws {
        SitesSpy.reset()
        let (runtime, host) = try await SitesHarness.hostRuntime()
        runtime.state = .ready
        let bridge = CEFBookmarkBridge(runtime: runtime)
        let (profile, store) = SitesHarness.store(in: bridge)
        var failures: [CEFBookmarkBridge.SyncFailure] = []
        let waiting = host.replies.count

        bridge.sync(store: store, treeJSON: #"{"nodes":[]}"#) { failures.append($0) }
        #expect(failures.isEmpty, "the remote's 1 (sent) was read as the host's answer")
        #expect(host.replies.count == waiting + 1)
        try SitesHarness.deliver(SitesSpy.lastToken, CEFReplyWaitersTests.int32(-1))

        #expect(failures == [.refused])
        #expect(bridge.stores[profile]?.isEmpty == true)
    }

    /// A whole-tree apply on a busy host can outlast the deadline: the store stays listed, so later
    /// cmux edits still reach it, and the failure says no answer, not a refusal.
    @Test func hostModeABookmarkSyncPastItsDeadlineKeepsTheStore() async throws {
        SitesSpy.reset()
        let (runtime, _) = try await SitesHarness.hostRuntime()
        runtime.state = .ready
        let rig = HostRepliesHarness.deadlines(of: runtime)
        let bridge = CEFBookmarkBridge(runtime: runtime)
        let (profile, store) = SitesHarness.store(in: bridge)
        var failures: [CEFBookmarkBridge.SyncFailure] = []

        bridge.sync(store: store, treeJSON: #"{"nodes":[]}"#) { failures.append($0) }
        rig.advance(by: CEFRuntime.siteReplyTimeout + .seconds(2))
        #expect(failures.isEmpty, "a whole-tree sync had only a site query's deadline")
        rig.advance(by: CEFBookmarkBridge.syncReplyTimeout)

        #expect(failures == [.noAnswer])
        #expect(bridge.stores[profile] == [store], "a sync the host may still apply forgot its store")
    }

    /// A refusal of a sync sent before the store reported again does not forget the live store.
    @Test func aStaleRefusalKeepsAStoreThatReportedAgain() async throws {
        SitesSpy.reset()
        let (runtime, _) = try await SitesHarness.hostRuntime()
        runtime.state = .ready
        let bridge = CEFBookmarkBridge(runtime: runtime)
        let (profile, store) = SitesHarness.store(in: bridge)
        var failures: [CEFBookmarkBridge.SyncFailure] = []

        bridge.sync(store: store, treeJSON: #"{"nodes":[]}"#) { failures.append($0) }
        let token = SitesSpy.lastToken
        bridge.arrived(json: #"{"op":"reset"}"#, cachePath: store)
        try SitesHarness.deliver(token, CEFReplyWaitersTests.int32(-1))

        #expect(failures == [.refused])
        #expect(bridge.stores[profile] == [store], "a stale refusal forgot a store that reported after the sync")
    }

    /// The host exited before it answered: the store is forgotten (the next host's stores report again).
    @Test func hostModeABookmarkSyncWhoseHostExitedForgetsTheStore() async throws {
        SitesSpy.reset()
        let (runtime, _) = try await SitesHarness.hostRuntime()
        runtime.state = .ready
        let bridge = CEFBookmarkBridge(runtime: runtime)
        let (profile, store) = SitesHarness.store(in: bridge)
        var failures: [CEFBookmarkBridge.SyncFailure] = []

        bridge.sync(store: store, treeJSON: #"{"nodes":[]}"#) { failures.append($0) }
        runtime.hostGone()

        #expect(failures == [.hostGone])
        #expect(bridge.stores[profile]?.isEmpty == true)
    }

    @Test func aBookmarkSyncWithoutChromiumIsRefusedAtOnce() throws {
        SitesSpy.reset()
        let runtime = try SitesHarness.inProcessRuntime()
        let bridge = CEFBookmarkBridge(runtime: runtime)
        var failures: [CEFBookmarkBridge.SyncFailure] = []

        bridge.sync(store: "/tmp/Profile-x", treeJSON: #"{"nodes":[]}"#) { failures.append($0) }

        #expect(failures == [.notRunning])
        #expect(SitesSpy.syncs.isEmpty)
    }
}

@MainActor enum SitesHarness {
    static func inProcessRuntime() throws -> CEFRuntime {
        let runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(SitesSpy.symbol), storage: HostRepliesHarness.storage())
        // Tabs and panes hold the runtime unowned and may schedule work past the test.
        _ = Unmanaged.passRetained(runtime)
        return runtime
    }

    /// A runtime in host mode: a `CEFHostStart` attached to the spy remote dylib.
    static func hostRuntime() async throws -> (CEFRuntime, CEFHostStart) {
        let runtime = try inProcessRuntime()
        let host = CEFHostStart(supervisor: OneSpyHost(), open: { _ in
            do throws(CEFShimLibrary.LoadError) { return .success(try CEFRemoteShim.make(symbol: SitesSpy.symbol, expected: SitesSpy.abi)) } catch { return .failure(.shim(error)) }
        })
        guard case .success = await host.attached() else { throw BrowserTabError.closed }
        runtime.hostStart = host
        #expect(SitesSpy.replySink?.context != nil, "the attach gave the remote shim no reply sink")
        return (runtime, host)
    }

    /// A tab of a new pane whose browser 7 exists.
    static func attachedTab(_ runtime: CEFRuntime) -> CEFTab {
        let tab = HostRepliesHarness.tab(in: HostRepliesHarness.pane(runtime, profile: .default).0)
        tab.attach(browser: 7)
        return tab
    }

    /// A store that reported to `bridge`, of a new profile.
    static func store(in bridge: CEFBookmarkBridge) -> (BrowserProfileID, String) {
        let id = UUID()
        let store = "/tmp/cmux-sites/Profile-\(id.uuidString)"
        bridge.arrived(json: #"{"op":"loaded"}"#, cachePath: store)
        return (BrowserProfileID(rawValue: id), store)
    }

    static func deliver(_ token: UInt32, _ fields: [UInt8]) throws {
        let sink = try #require(SitesSpy.replySink)
        let reply = try #require(sink.reply)
        fields.withUnsafeBytes { reply(sink.context, token, $0.baseAddress, $0.count) }
    }

    static func object(_ json: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }
}

/// The remote dylib (and in-process shim) of these tests: the wire entry points as
/// ``HostRepliesSpy``'s, and the ops the sites send, recorded. Its async exports make the next
/// token current, as the remote shim's PostForReply does. Every other function returns 0.
nonisolated enum SitesSpy {
    static let abi = "sites-spy-abi"
    // crash-allow: test-only spy state, read and written on the main thread by a serialized suite and the C stand-ins it calls there
    nonisolated(unsafe) static var lastToken: UInt32 = 0
    // crash-allow: test-only spy state (see lastToken)
    nonisolated(unsafe) static var calls: [String] = []
    // crash-allow: test-only spy state (see lastToken)
    nonisolated(unsafe) static var sends: [String] = []
    // crash-allow: test-only spy state (see lastToken)
    nonisolated(unsafe) static var syncs: [String] = []
    // crash-allow: test-only spy state (see lastToken)
    nonisolated(unsafe) static var devToolsSendAnswer: Int32 = 1
    // crash-allow: test-only spy state (see lastToken)
    nonisolated(unsafe) static var bookmarksAnswer: Int32 = 1
    // crash-allow: test-only spy state (see lastToken)
    nonisolated(unsafe) static var replySink: (context: UnsafeMutableRawPointer?, reply: CEFRemoteShim.ReplyFn?)?
    // crash-allow: a C string made once and never freed, read only
    nonisolated(unsafe) private static let abiCString = strdup(abi)

    static func reset() {
        lastToken = 0
        calls = []
        sends = []
        syncs = []
        devToolsSendAnswer = 1
        bookmarksAnswer = 1
        replySink = nil
    }

    static func text(_ pointer: UnsafePointer<CChar>?) -> String {
        pointer.map { String(cString: $0) } ?? ""
    }

    static func sent() {
        lastToken += 1
    }

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let abiID: @convention(c) () -> UnsafePointer<CChar>? = { UnsafePointer(SitesSpy.abiCString) }
        let attach: CEFRemoteShim.AttachFn = { _, _, _, context, hello in
            hello?(context, 1, nil)
            return 1
        }
        let detach: CEFRemoteShim.DetachFn = {}
        let setReply: CEFRemoteShim.SetReplyFn = { context, reply in SitesSpy.replySink = (context, reply) }
        let lastReplyToken: CEFRemoteShim.LastReplyTokenFn = { SitesSpy.lastToken }
        let devToolsSend: @convention(c) (Int32, UnsafePointer<CChar>?) -> Int32 = { _, message in
            SitesSpy.sends.append(SitesSpy.text(message))
            SitesSpy.sent()
            return SitesSpy.devToolsSendAnswer
        }
        let bookmarksSync: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { store, _ in
            SitesSpy.syncs.append(SitesSpy.text(store))
            SitesSpy.sent()
            return SitesSpy.bookmarksAnswer
        }
        // The posts answer what a gone browser would: the sites must not read it.
        let printPage: @convention(c) (Int32) -> Int32 = { browser in
            SitesSpy.calls.append("print \(browser)")
            return 0
        }
        let certificate: @convention(c) (Int32, UnsafePointer<CChar>?, Int32, Int32) -> Int32 = { browser, host, code, decides in
            SitesSpy.calls.append("certificate \(browser) \(SitesSpy.text(host)) \(code) \(decides)")
            return 0
        }
        let load: @convention(c) (Int32, UnsafePointer<CChar>?) -> Void = { browser, url in
            SitesSpy.calls.append("load \(browser) \(SitesSpy.text(url))")
        }
        let downloadURL: @convention(c) (Int32, UnsafePointer<CChar>?) -> Int32 = { browser, url in
            SitesSpy.calls.append("download \(browser) \(SitesSpy.text(url))")
            return 0
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_shim_abi_id": unsafeBitCast(abiID, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_attach": unsafeBitCast(attach, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_detach": unsafeBitCast(detach, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_set_reply": unsafeBitCast(setReply, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_last_reply_token": unsafeBitCast(lastReplyToken, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_devtools_send": unsafeBitCast(devToolsSend, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_bookmarks_sync": unsafeBitCast(bookmarksSync, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_print": unsafeBitCast(printPage, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_certificate_proceed": unsafeBitCast(certificate, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_load_url": unsafeBitCast(load, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_download_url": unsafeBitCast(downloadURL, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
