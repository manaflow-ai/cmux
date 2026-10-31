import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileBrowserStream

@Suite struct AnnexBTests {
    @Test func splitsStartCodesAndBuildsAVCC() {
        let sps: [UInt8] = [0x67, 1, 2]
        let pps: [UInt8] = [0x68, 3]
        let idr: [UInt8] = [0x65, 9, 9, 9]
        let aud: [UInt8] = [0, 0, 0, 1, 0x09, 0xF0]
        let start4: [UInt8] = [0, 0, 0, 1]
        let start3: [UInt8] = [0, 0, 1]
        var stream: [UInt8] = aud
        stream += start4 + sps
        stream += start3 + pps
        stream += start4 + idr
        let bytes = Data(stream)
        let unit = AnnexBAccessUnit(bytes)
        #expect(unit.sps == Data(sps))
        #expect(unit.pps == Data(pps))
        #expect(unit.isIDR)
        #expect(unit.units == [Data(idr)])
        let length: [UInt8] = [0, 0, 0, 4]
        #expect(unit.avcc == Data(length + idr))
        let p = AnnexBAccessUnit(Data([0, 0, 1, 0x41, 7, 7]))
        #expect(!p.isIDR && p.sps == nil && p.units == [Data([0x41, 7, 7])])
    }
}

@Suite struct WireTests {
    func object(_ data: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:] }

    @Test func screenCapsTheScaleAtTwo() {
        let screen = RemoteBrowserWire.Screen(points: CGSize(width: 402, height: 700.4), screenScale: 3)
        #expect(screen == .init(cssWidth: 402, cssHeight: 700, scale: 2))
        let open = object(RemoteBrowserWire().open(tab: "s4", viewer: "phone", screen: screen))
        #expect(open["t"] as? String == "rb.open")
        #expect((open["screen"] as? [String: Any])?["css_width"] as? Int == 402)
    }

    @Test func theOverlayNamesTheMediaLanesCarrier() {
        #expect(BrowserStreamStats.carrier(videoTrack: true, transport: .webRTC) == "track")
        #expect(BrowserStreamStats.carrier(videoTrack: true, transport: .wireGuard) == "wg-rtp")
        #expect(BrowserStreamStats.carrier(videoTrack: false, transport: .wireGuard) == "channel")
        #expect(BrowserStreamStats().videoCarrier == "channel")
    }

    @Test func inputEventsMatchTheRbSchema() {
        let wire = RemoteBrowserWire()
        let down = object(wire.pointer("down", x: 10, y: 20, buttons: 1))
        #expect(down["e"] as? String == "pointer" && down["kind"] as? String == "down" && down["click_count"] as? Int == 1)
        let wheel = object(wire.wheel(x: 1, y: 2, dx: 0, dy: -30, phase: "changed", momentum: "none"))
        #expect(wheel["precise"] as? Bool == true && wheel["dy"] as? Double == -30)
        let commit = object(wire.commit("héllo"))
        #expect(commit["e"] as? String == "ime_commit" && commit["text"] as? String == "héllo" && commit["replacement"] is NSNull)
        let key = object(wire.key("Backspace", key: "Backspace", down: true))
        #expect(key["code"] as? String == "Backspace" && (key["edit_commands"] as? [Any])?.isEmpty == true)
    }
}

final class FakeStream: BrowserStreamConnection, @unchecked Sendable {
    let lock = NSLock()
    var messages: [[String: Any]] = []
    var inputs: [[String: Any]] = []
    var closed = false

    func send(message: Data) throws {
        lock.withLock { messages.append((try? JSONSerialization.jsonObject(with: message) as? [String: Any]) ?? [:]) }
    }
    func send(input: Data, mustDeliver: Bool) throws {
        lock.withLock { inputs.append((try? JSONSerialization.jsonObject(with: input) as? [String: Any]) ?? [:]) }
    }
    var keyframeRequests = 0
    func requestKeyframe() { lock.withLock { keyframeRequests += 1 } }
    func noteDecode(micros: UInt32) {}
    func stats() -> BrowserStreamStats { BrowserStreamStats() }
    func nowMicros() -> UInt64 { 0 }
    func close() { lock.withLock { closed = true } }
    var keyframes: Int { lock.withLock { keyframeRequests } }
    var isClosed: Bool { lock.withLock { closed } }
    var sent: [String] { lock.withLock { messages.compactMap { $0["t"] as? String } } }
}

final class SinkBox: @unchecked Sendable {
    let lock = NSLock()
    var sinks: [any BrowserStreamSink] = []
    var last: (any BrowserStreamSink)? { lock.withLock { sinks.last } }
}

@MainActor @Suite struct ModelTests {
    func settle() async { for _ in 0..<20 { await Task.yield() } }

    @Test func opensAtThePhonesSizeAndFollowsThePage() async throws {
        let stream = FakeStream()
        let box = SinkBox()
        let model = StreamedBrowserModel(tab: "s4", url: URL(string: "https://example.com")) { sink in
            box.lock.withLock { box.sinks.append(sink) }
            return stream
        }
        model.setVisible(true)
        model.layout(points: CGSize(width: 402, height: 700), screenScale: 3)
        for _ in 0..<200 where box.last == nil { try? await Task.sleep(for: .milliseconds(5)) }
        let sink = try #require(box.last)
        #expect(model.phase == .connecting)
        sink.browserMessage(Data(#"{"t":"welcome","caps":["input.service"]}"#.utf8))
        await settle()
        #expect(stream.sent == ["rb.open", "rb.visibility"])
        sink.browserMessage(Data(#"{"t":"rb.page","url":"https://example.org/a","title":"A","loading":true,"can_go_back":true,"can_go_forward":false}"#.utf8))
        await settle()
        #expect(model.url?.absoluteString == "https://example.org/a" && model.title == "A" && model.isLoading && model.canGoBack)
        #expect(model.host == "example.org")
        model.layout(points: CGSize(width: 402, height: 500), screenScale: 3)
        model.goBack()
        model.reloadOrStop()
        model.navigate(to: "swift.org")
        #expect(stream.sent == ["rb.open", "rb.visibility", "rb.screen", "rb.history", "rb.history", "rb.navigate"])
        #expect(stream.lock.withLock { stream.messages[4]["op"] as? String } == "stop")
        #expect(stream.lock.withLock { stream.messages[5]["url"] as? String } == "https://swift.org")
        let (x, y) = model.css(CGPoint(x: 201, y: 250), in: CGSize(width: 402, height: 500))
        #expect(x == 201 && y == 250)
        // A dropped stream waits, then opens again on the next link.
        sink.browserClosed(code: "link_closed", reason: "")
        await settle()
        if case .waiting = model.phase {} else { Issue.record("expected waiting") }
        model.reconnect()
        await settle()
        #expect(box.lock.withLock { box.sinks.count } == 2)
    }

    @Test func aRefusedOpenSaysWhy() async {
        let model = StreamedBrowserModel(tab: "s4", url: nil) { _ in throw LinkError(code: "unavailable", message: "browser host: exited") }
        model.setVisible(true)
        model.layout(points: CGSize(width: 300, height: 600), screenScale: 2)
        for _ in 0..<200 where model.phase == .connecting { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(model.phase == .waiting("browser host: exited"))
    }

    /// The Mac's reason for an address it does not open is shown as it is; an older
    /// Mac's bare scheme list becomes what to do about it.
    @Test func aForbiddenOpenShowsTheMacsSentence() async {
        for (message, shown) in [
            ("This file isn't in a folder this Mac shares with your iPhone.", "This file isn't in a folder this Mac shares with your iPhone."),
            ("only http, https and about:blank load", "Update cmux on your Mac to open this page on your iPhone."),
        ] {
            let model = StreamedBrowserModel(tab: "s4", url: URL(string: "file:///Users/me/x.html")) { _ in
                throw LinkError(code: "forbidden", message: message)
            }
            model.setVisible(true)
            model.layout(points: CGSize(width: 300, height: 600), screenScale: 2)
            for _ in 0..<200 where model.phase == .connecting { try? await Task.sleep(for: .milliseconds(5)) }
            #expect(model.phase == .waiting(shown))
        }
    }

    /// A Mac with no browser host (this build's code, or an older Mac's words) is an
    /// honest state, never the raw reason.
    @Test func aMacWithoutABrowserHostIsUnavailable() async {
        for error in [LinkError(code: "no_browser_host", message: "this Mac does not stream browser tabs"),
                      LinkError(code: "unavailable", message: "this build has no browser host")] {
            let model = StreamedBrowserModel(tab: "s5", url: nil) { _ in throw error }
            model.setVisible(true)
            model.layout(points: CGSize(width: 300, height: 600), screenScale: 2)
            for _ in 0..<200 where model.phase == .connecting { try? await Task.sleep(for: .milliseconds(5)) }
            #expect(model.phase == .unavailable)
        }
    }
}

/// A Mac without a browser host reads as an honest state, never its raw reason.
@Suite struct NoBrowserHostTests {
    @Test func theMacsMissingHostIsRecognized() {
        #expect(LinkErrorText.noBrowserHost(LinkError(code: "no_browser_host", message: "this Mac does not stream browser tabs")))
        #expect(LinkErrorText.noBrowserHost(LinkError(code: "unavailable", message: "this build has no browser host")))
        #expect(!LinkErrorText.noBrowserHost(LinkError(code: "unavailable", message: "browser host vanished")))
        #expect(!LinkErrorText.noBrowserHost(LinkError(code: "no-link", message: "Not connected to the Mac")))
    }
}

/// Parity findings 4 and 5 (verify/parity-mac.md): Forward right after Back, and the address
/// while a navigation loads.
@MainActor @Suite struct BrowserHistoryTests {
    func page(_ url: String, loading: Bool, back: Bool, forward: Bool) -> RemoteBrowserPage {
        RemoteBrowserPage(json: ["t": "rb.page", "url": url, "title": "", "loading": loading, "can_go_back": back, "can_go_forward": forward])!
    }

    func model() async throws -> (StreamedBrowserModel, FakeStream) {
        let stream = FakeStream()
        let box = SinkBox()
        let model = StreamedBrowserModel(tab: "s4", url: nil) { sink in
            box.lock.withLock { box.sinks.append(sink) }
            return stream
        }
        model.setVisible(true)
        model.layout(points: CGSize(width: 402, height: 700), screenScale: 3)
        for _ in 0..<200 where box.last == nil { try? await Task.sleep(for: .milliseconds(5)) }
        let sink = try #require(box.last)
        sink.browserMessage(Data(#"{"t":"welcome","caps":[]}"#.utf8))
        for _ in 0..<20 { await Task.yield() }
        return (model, stream)
    }

    func ops(_ stream: FakeStream) -> [String] {
        stream.lock.withLock { stream.messages.filter { $0["t"] as? String == "rb.history" }.compactMap { $0["op"] as? String } }
    }

    /// Finding 5: the browser reports the old history while Back loads, so Forward stayed
    /// disabled (or was ignored) until a second tap. Forward is offered at once, and a tap
    /// before Back commits is sent once it does, exactly once.
    @Test func forwardRightAfterBackNeedsOneTap() async throws {
        let (model, stream) = try await model()
        model.apply(page("https://iana.org/", loading: false, back: true, forward: false))
        model.goBack()
        #expect(model.canGoForward)
        // The Mac starts loading the previous page and still reports no forward entry.
        model.apply(page("https://iana.org/", loading: true, back: true, forward: false))
        #expect(model.canGoForward)
        model.goForward()
        #expect(ops(stream) == ["back"])
        model.apply(page("https://example.com/", loading: false, back: false, forward: true))
        #expect(ops(stream) == ["back", "forward"])
        #expect(model.canGoBack)
        model.apply(page("https://example.com/", loading: true, back: false, forward: true))
        model.apply(page("https://iana.org/", loading: false, back: true, forward: false))
        #expect(ops(stream) == ["back", "forward"])
        #expect(model.canGoBack && !model.canGoForward)
    }

    /// A step the Mac committed without a loading report (a cached page) still counts.
    @Test func aCachedStepCommitsOnTheNewAddress() async throws {
        let (model, stream) = try await model()
        model.apply(page("https://iana.org/", loading: false, back: true, forward: false))
        model.goBack()
        model.apply(page("https://example.com/", loading: false, back: false, forward: true))
        model.goForward()
        #expect(ops(stream) == ["back", "forward"])
    }

    /// Finding 4: a new tab reports about:blank while the typed address loads; the address
    /// stays the one asked for, then follows the page.
    @Test func theAddressIsTheOneAskedForWhileItLoads() async throws {
        let (model, _) = try await model()
        model.apply(page("about:blank", loading: false, back: false, forward: false))
        model.navigate(to: "example.com")
        model.apply(page("about:blank", loading: true, back: false, forward: false))
        #expect(model.url?.absoluteString == "https://example.com" && model.host == "example.com")
        model.apply(page("https://example.com/", loading: false, back: true, forward: false))
        #expect(model.url?.absoluteString == "https://example.com/")
        // Later reports follow the page again.
        model.apply(page("https://example.com/next", loading: false, back: true, forward: false))
        #expect(model.host == "example.com" && model.url?.path() == "/next")
    }
}

/// The address bar of a streamed tab hands the Mac what the person typed: other
/// schemes and Mac paths too, so the Mac decides and says why it refuses
/// (cmux-next-ios/PROTOCOL.md `browser`, addresses).
@MainActor @Suite struct StreamedAddressTests {
    func url(_ text: String) -> String? { StreamedBrowserModel.url(for: text)?.absoluteString }

    @Test func otherSchemesAndMacPathsGoToTheMac() {
        #expect(url("file:///Users/me/verify/page.html") == "file:///Users/me/verify/page.html")
        #expect(url("/Users/me/my page.html") == "file:///Users/me/my%20page.html")
        #expect(url("data:text/html,hi") == "data:text/html,hi")
        #expect(url("about:blank") == "about:blank")
        #expect(url("view-source:https://example.com") == "view-source:https://example.com")
        // Refused by the Mac, with its reason: still sent, never turned into a search.
        #expect(url("javascript:alert(1)") == "javascript:alert(1)")
        #expect(url("chrome://settings") == "chrome://settings")
        #expect(url("zoommtg://zoom.us/join") == "zoommtg://zoom.us/join")
        #expect(url("mailto:a@b.c") == "mailto:a@b.c")
        #expect(url("//server/share")?.hasPrefix("https://duckduckgo.com/") == true)
        #expect(url("localhost:3000") == "http://localhost:3000")
        #expect(url("tel:911") == "tel:911")
        #expect(url("mac.local:8080/x") == "http://mac.local:8080/x")
        // Unchanged: hosts, searches, web addresses.
        #expect(url("example.com") == "https://example.com")
        #expect(url("https://example.com/a") == "https://example.com/a")
        #expect(url("two words")?.hasPrefix("https://duckduckgo.com/?q=two") == true)
    }
}

@MainActor @Suite struct RefusedNavigationTests {
    func model() async throws -> (StreamedBrowserModel, FakeStream, any BrowserStreamSink) {
        let stream = FakeStream()
        let box = SinkBox()
        let model = StreamedBrowserModel(tab: "s4", url: nil) { sink in
            box.lock.withLock { box.sinks.append(sink) }
            return stream
        }
        model.setVisible(true)
        model.layout(points: CGSize(width: 402, height: 700), screenScale: 3)
        for _ in 0..<200 where box.last == nil { try? await Task.sleep(for: .milliseconds(5)) }
        let sink = try #require(box.last)
        sink.browserMessage(Data(#"{"t":"welcome","caps":[]}"#.utf8))
        for _ in 0..<20 { await Task.yield() }
        return (model, stream, sink)
    }

    /// The Mac refuses an address: the page stays, the address bar goes back to
    /// it, and the person reads why, in words, until the next navigation.
    @Test func aRefusedAddressSaysWhyAndKeepsThePage() async throws {
        let (model, stream, sink) = try await model()
        model.apply(RemoteBrowserPage(json: ["t": "rb.page", "url": "https://example.com/", "title": "", "loading": false, "can_go_back": false, "can_go_forward": false])!)
        model.navigate(to: "file:///Users/me/.ssh/id_ed25519")
        #expect(stream.lock.withLock { stream.messages.last?["url"] as? String } == "file:///Users/me/.ssh/id_ed25519")
        sink.browserMessage(Data(#"{"t":"rb.navigate.refused","url":"file:///Users/me/.ssh/id_ed25519","code":"file_not_shared","reason":"This file isn't in a folder this Mac shares with your iPhone."}"#.utf8))
        for _ in 0..<20 { await Task.yield() }
        #expect(model.notice == "This file isn't in a folder this Mac shares with your iPhone.")
        #expect(model.url?.absoluteString == "https://example.com/")
        #expect(model.phase != .waiting("This file isn't in a folder this Mac shares with your iPhone."))
        model.navigate(to: "example.org")
        #expect(model.notice == nil)
        // A link inside the page the Mac took back: said too, the address follows the page.
        sink.browserMessage(Data(#"{"t":"rb.navigate.refused","url":"javascript:x","code":"script","reason":"Scripts can't run from your iPhone's address bar."}"#.utf8))
        for _ in 0..<20 { await Task.yield() }
        #expect(model.notice == "Scripts can't run from your iPhone's address bar.")
        model.dismissNotice()
        #expect(model.notice == nil)
    }
}

/// Keyboard input to a streamed page: what each key sends, and how much of the page
/// the keyboard covers (the page lays out above it).
@Suite struct StreamedKeyboardTests {
    let wire = RemoteBrowserWire()

    func object(_ data: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:] }

    @Test func typedTextReturnAndTab() {
        let text = StreamedBrowserKey.typed("héllo 👋", wire: wire).map(object)
        #expect(text.count == 1 && text[0]["e"] as? String == "ime_commit" && text[0]["text"] as? String == "héllo 👋")
        let enter = StreamedBrowserKey.typed("\n", wire: wire).map(object)
        #expect(enter.map { $0["down"] as? Bool } == [true, false])
        #expect(enter.allSatisfy { $0["code"] as? String == "Enter" && $0["text"] as? String == "\r" })
        let tab = StreamedBrowserKey.typed("\t", wire: wire).map(object)
        #expect(tab.first?["code"] as? String == "Tab")
        #expect(StreamedBrowserKey.typed("", wire: wire).isEmpty)
    }

    @Test func barKeysAndShortcuts() {
        let all = StreamedBrowserKey.selectAll.events(wire).map(object)
        #expect(all[0]["code"] as? String == "KeyA" && all[0]["modifiers"] as? Int == 8)
        #expect((all[0]["edit_commands"] as? [[String: String]])?.first?["name"] == "SelectAll")
        #expect((all[1]["edit_commands"] as? [Any])?.isEmpty == true && all[1]["down"] as? Bool == false)
        #expect(StreamedBrowserKey.escape.events(wire).map(object).first?["code"] as? String == "Escape")
        #expect(StreamedBrowserKey.left.events(wire).map(object).first?["key"] as? String == "ArrowLeft")
        #expect(StreamedBrowserKey.copy.events(wire).map(object).first?["modifiers"] as? Int == 8)
    }

    @Test func theKeyboardCoversTheBottomOfThePage() {
        let page = CGRect(x: 0, y: 59, width: 402, height: 700)
        #expect(StreamedBrowserKey.covered(page: page, keyboard: nil) == 0)
        #expect(StreamedBrowserKey.covered(page: page, keyboard: CGRect(x: 0, y: 874, width: 402, height: 336)) == 0)
        #expect(StreamedBrowserKey.covered(page: page, keyboard: CGRect(x: 0, y: 500, width: 402, height: 374)) == 259)
        #expect(StreamedBrowserKey.covered(page: page, keyboard: CGRect(x: 0, y: 0, width: 402, height: 874)) == 700)
    }
}

/// A Mac phone tab's simulator streams through the browser tab's model (verify/simulator-surface.md).
@MainActor @Suite struct SimulatorSurfaceTests {
    final class Link: BrowserStreamOpening, @unchecked Sendable {
        let stream = FakeStream()
        let box = SinkBox()
        var surfaces: [String] = []
        var browsers = 0
        func openBrowser(tab: String, url: String?, sink: any BrowserStreamSink) async throws -> any BrowserStreamConnection {
            browsers += 1
            return stream
        }
        func openSurface(tab: String, sink: any BrowserStreamSink) async throws -> any BrowserStreamConnection {
            box.lock.withLock { box.sinks.append(sink) }
            surfaces.append(tab)
            return stream
        }
    }

    @Test func aPhoneTabOpensTheSurfaceServiceAndSendsTouchesAtTheScreensUnitPoints() async throws {
        let link = Link()
        let directory = StreamedBrowserDirectory()
        directory.opener = { link }
        let model = try #require(directory.simulatorModel(tab: "s12"))
        #expect(directory.simulatorModel(tab: "s12") === model)
        model.setVisible(true)
        model.layout(points: CGSize(width: 402, height: 700), screenScale: 3)
        for _ in 0..<200 where link.box.last == nil { try? await Task.sleep(for: .milliseconds(5)) }
        let sink = try #require(link.box.last)
        #expect(link.surfaces == ["s12"] && link.browsers == 0)
        sink.browserMessage(Data(#"{"t":"welcome","caps":["input.service"]}"#.utf8))
        for _ in 0..<20 { await Task.yield() }
        #expect(link.stream.sent == ["rb.open", "rb.visibility"])
        model.touch("down", at: CGPoint(x: 0.25, y: 0.5))
        model.touch("move", at: CGPoint(x: 0.3, y: 0.6))
        model.touch("up", at: CGPoint(x: 0.3, y: 0.6))
        model.pressButton("home")
        let inputs = link.stream.lock.withLock { link.stream.inputs }
        #expect(inputs.map { $0["kind"] as? String ?? $0["e"] as? String } == ["down", "move", "up", "button"])
        #expect(inputs[0]["x"] as? Double == 0.25 && inputs[0]["y"] as? Double == 0.5)
        #expect(inputs[3]["button"] as? String == "home")
        // Hidden: the Mac hears it (the shown tab takes the media lane back).
        model.setVisible(false)
        #expect(link.stream.sent.last == "rb.visibility")
    }

    @Test func pointsMapOntoTheAspectFitPictureAndClamp() {
        let view = CGSize(width: 400, height: 1000)
        // A 1:2 picture in a 400x1000 view is 400x800, 100 pt from the top.
        let picture = CGSize(width: 882, height: 1764)
        #expect(StreamedBrowserModel.normalized(CGPoint(x: 200, y: 500), in: view, picture: picture) == CGPoint(x: 0.5, y: 0.5))
        #expect(StreamedBrowserModel.normalized(CGPoint(x: 0, y: 100), in: view, picture: picture) == CGPoint(x: 0, y: 0))
        #expect(StreamedBrowserModel.normalized(CGPoint(x: 500, y: 10), in: view, picture: picture) == CGPoint(x: 1, y: 0))
        // Before the first frame the picture fills the view.
        #expect(StreamedBrowserModel.normalized(CGPoint(x: 100, y: 250), in: view, picture: .zero) == CGPoint(x: 0.25, y: 0.25))
    }

    @Test func aMacThatStreamsNoSimulatorsIsUnavailable() async {
        for error in [LinkError(code: "no_surface_host", message: "this Mac does not stream simulator tabs"),
                      LinkError(code: "unknown_service", message: "no service surface")] {
            let model = StreamedBrowserModel(tab: "s12", url: nil) { _ in throw error }
            model.setVisible(true)
            model.layout(points: CGSize(width: 300, height: 600), screenScale: 2)
            for _ in 0..<200 where model.phase == .connecting { try? await Task.sleep(for: .milliseconds(5)) }
            #expect(model.phase == .unavailable)
        }
    }
}

/// The page's focused field and a hardware keyboard's keys.
@Suite struct StreamedFocusAndHardwareKeyTests {
    let wire = RemoteBrowserWire()

    @Test func theFocusedFieldIsRead() {
        let field = StreamedBrowserField(json: ["t": "rb.text_input", "input_type": "search",
                                                "caret": ["x": 10.0, "y": 140.0, "width": 1.0, "height": 18.0]])
        #expect(field?.inputType == "search" && field?.caret == CGRect(x: 10, y: 140, width: 1, height: 18))
        #expect(StreamedBrowserField(json: ["input_type": "none"]) == nil)
        #expect(StreamedBrowserField(json: ["input_type": "text"])?.caret == nil)
    }

    @Test func arrowsEscapeAndShortcutsGoToThePage() {
        let left = StreamedHardwareKey(usage: 0x50, characters: "", modifiers: [])
        #expect(left?.code == "ArrowLeft" && left?.editCommands == [])
        #expect(StreamedHardwareKey(usage: 0x29, characters: "", modifiers: [])?.code == "Escape")
        let all = StreamedHardwareKey(usage: 0x04, characters: "a", modifiers: .command)
        #expect(all?.code == "KeyA" && all?.editCommands == ["SelectAll"])
        #expect(StreamedHardwareKey(usage: 0x1D, characters: "z", modifiers: [.command, .shift])?.editCommands == ["Redo"])
        #expect(StreamedHardwareKey(usage: 0x50, characters: "", modifiers: [.option, .shift])?.editCommands
            == ["MoveWordLeftAndModifySelection"])
        #expect(StreamedHardwareKey(usage: 0x4F, characters: "", modifiers: .command)?.editCommands == ["MoveToEndOfLine"])
        #expect(StreamedHardwareKey(usage: 0x1E, characters: "1", modifiers: .control)?.code == "Digit1")
        // Typing keys stay on the text path.
        #expect(StreamedHardwareKey(usage: 0x04, characters: "a", modifiers: []) == nil)
        #expect(StreamedHardwareKey(usage: 0x04, characters: "A", modifiers: .shift) == nil)
        #expect(StreamedHardwareKey(usage: 0x28, characters: "\r", modifiers: []) == nil)
        #expect(StreamedHardwareKey(usage: 0x2A, characters: "", modifiers: []) == nil)
        let events = StreamedHardwareKey(usage: 0x52, characters: "", modifiers: .command)!.events(wire)
        let down = (try? JSONSerialization.jsonObject(with: events[0]) as? [String: Any]) ?? [:]
        #expect(down["code"] as? String == "ArrowUp" && down["modifiers"] as? Int == 8)
    }
}


@MainActor @Suite struct FocusResetTests {
    /// The host reports focus only when it changes: a new session starts with none.
    @Test func aNewSessionForgetsTheFocusedField() async throws {
        let stream = FakeStream()
        let box = SinkBox()
        let model = StreamedBrowserModel(tab: "s4", url: nil) { sink in
            box.lock.withLock { box.sinks.append(sink) }
            return stream
        }
        model.setVisible(true)
        model.layout(points: CGSize(width: 402, height: 700), screenScale: 3)
        for _ in 0..<200 where box.last == nil { try? await Task.sleep(for: .milliseconds(5)) }
        let sink = try #require(box.last)
        sink.browserMessage(Data(#"{"t":"welcome","caps":[]}"#.utf8))
        sink.browserMessage(Data(#"{"t":"rb.text_input","input_type":"password","composition_rects":[],"caret":null}"#.utf8))
        for _ in 0..<20 { await Task.yield() }
        #expect(model.field?.inputType == "password")
        sink.browserClosed(code: "link_closed", reason: "")
        for _ in 0..<20 { await Task.yield() }
        #expect(model.field == nil)
    }
}

/// A file page's short label is its name, never the whole path (PR #24708).
@MainActor @Suite struct BrowserDisplayHostTests {
    @Test func fileURLShowsItsName() {
        let url = URL(string: "file:///Users/me/worktrees/feat/verify/iphone-link-sequence.html")
        #expect(StreamedBrowserModel.displayHost(url) == "iphone-link-sequence.html")
        #expect(StreamedBrowserModel.displayHost(URL(string: "https://www.example.com/a")) == "example.com")
    }
}
