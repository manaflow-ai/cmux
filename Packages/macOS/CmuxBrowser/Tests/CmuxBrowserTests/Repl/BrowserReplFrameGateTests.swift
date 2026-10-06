import AppKit
import WebKit
import Testing

@testable import CmuxBrowser

/// The domain policy applies to every frame of a tab, not only the main
/// frame: a page the policy allows can embed a frame that shows a page it
/// blocks (a user's tab has no content rules, and a frame can load before
/// the policy is set). These tests load real pages in WebKit, served by a
/// scheme handler for `cmux-test://allowed.test` and `cmux-test://blocked.test`.
@MainActor
@Suite("Frame gate", .serialized)
struct BrowserReplFrameGateTests {
    // MARK: auth.request

    /// `auth.request` fills credentials into one frame; the gate must refuse
    /// a frame that shows a blocked page, whatever the main frame shows.
    @Test func authorizeRefusesAFrameThatShowsABlockedPage() async throws {
        let page = try await FramePage.load()
        let gate = Self.gate()
        let blocked = try #require(page.frame(host: "blocked.test"))
        let error = await Self.error { try await gate.authorize(blocked, in: page.webView) }
        #expect(error?.code == "blocked", "a frame on a blocked domain was authorized")
        let allowed = try #require(page.frame(path: "/child"))
        #expect(await Self.error { try await gate.authorize(allowed, in: page.webView) } == nil)
        #expect(await Self.error { try await gate.authorize(page.main, in: page.webView) } == nil)
    }

    @Test func authorizeRefusesAMainFrameThatShowsABlockedPage() async throws {
        let page = try await FramePage.load(url: "cmux-test://blocked.test/")
        let gate = Self.gate()
        let error = await Self.error { try await gate.authorize(page.main, in: page.webView) }
        #expect(error?.code == "blocked", "a main frame on a blocked domain was authorized")
    }

    // MARK: Reads, input and captures

    /// `frame.evaluate` and every other script the driver runs for the
    /// session in a frame: a frame that shows a blocked page is not read.
    @Test func aFrameThatShowsABlockedPageIsNotEvaluated() async throws {
        let page = try await FramePage.load()
        let gate = Self.gate()
        let blocked = try #require(page.frame(host: "blocked.test"))
        let read = "return document.body.innerText"
        let error = await Self.error {
            try await gate.callAsyncJavaScript(read, arguments: [:], in: page.webView, frame: blocked, contentWorld: .page)
        }
        #expect(error?.code == "blocked", "a frame on a blocked domain was read: \(String(describing: error))")
        let allowed = try #require(page.frame(path: "/child"))
        let text = try await gate.callAsyncJavaScript(read, arguments: [:], in: page.webView, frame: allowed, contentWorld: .page)
        #expect((text as? String)?.contains("allowed.test/child") == true)
    }

    /// Two frames of one site that both relax `document.domain` to it are
    /// one origin to page script: script in the allowed frame (any world
    /// agent code reaches) would read the sibling the policy blocks. The
    /// gate refuses script in a frame such a blocked frame shares a site
    /// with, before and after it runs.
    @Test(arguments: [false, true])
    func aFrameThatCanRelaxIntoABlockedSiblingIsNotEvaluated(agentWorld: Bool) async throws {
        let child = "<p>CHILD</p><script>document.domain = 'site.test'</script>"
        let page = try await FramePage.load(
            url: "cmux-test://main.site.test/",
            html: """
            <iframe src="cmux-test://a.site.test/a"></iframe>
            <iframe src="cmux-test://b.site.test/b"></iframe>
            """,
            loaded: { $0.count >= 3 && $0.dropFirst().allSatisfy { !$0.url.isEmpty } },
            childPage: child
        )
        let allowed = try #require(page.frame(host: "a.site.test"))
        let read = "return parent.frames[1].document.body.innerText"
        // The page really relaxed: without the gate, the allowed frame reads
        // the blocked one.
        let raw = try await page.run(read, in: allowed) as? String
        try #require(raw?.contains("b.site.test") == true, "this WebKit does not relax document.domain here; nothing to guard")
        let gate = Self.gate(prohibiting: "cmux-test://b.site.test")
        let world: WKContentWorld = agentWorld ? .world(name: "cmux-frame-gate-agent") : .page
        let error = await Self.error {
            try await gate.callAsyncJavaScript(read, arguments: [:], in: page.webView, frame: allowed, contentWorld: world)
        }
        #expect(error?.code == "blocked", "script in a frame reached a blocked sibling of its site: \(String(describing: error))")
        // A frame of another site is not refused for it.
        let other = Self.gate(prohibiting: "cmux-test://blocked.example")
        #expect(await Self.error {
            try await other.callAsyncJavaScript("return 1", arguments: [:], in: page.webView, frame: allowed, contentWorld: world)
        } == nil)
    }

    /// A frame keeps its id when it navigates, and the driver looks frames up
    /// by id from an earlier tree read: a frame that moved to a blocked page
    /// since must not be read through the old record, and the script must
    /// not run there at all.
    @Test func aFrameThatNavigatedToABlockedPageIsNotEvaluatedThroughItsOldRecord() async throws {
        let page = try await FramePage.load()
        let gate = Self.gate()
        let child = try #require(page.frame(path: "/child"))
        _ = try await gate.callAsyncJavaScript("return 1", arguments: [:], in: page.webView, frame: child, contentWorld: .page)
        _ = try await page.run("document.getElementById('a').src = 'cmux-test://blocked.test/moved'; return true", in: page.main)
        _ = try await FramePage.settle(page.webView) { frames in
            frames.contains { $0.url == "cmux-test://blocked.test/moved" }
        }
        let error = await Self.error {
            try await gate.callAsyncJavaScript(
                "window.__ranByGate = true; return document.body.innerText",
                arguments: [:],
                in: page.webView,
                frame: child,
                contentWorld: .page
            )
        }
        #expect(error?.code == "blocked", "the moved frame was read: \(String(describing: error))")
        let ran = try await page.run("return window.__ranByGate === true", in: child)
        #expect(ran as? Bool == false, "the script ran in the blocked document")
    }

    /// The gate's document check reads `location`. A script that declares
    /// its own `location` (a hoisted function) must not replace the one the
    /// check reads: the blocked page answers for such a function through
    /// `Function.prototype`, which it owns in its world, with the allowed
    /// document's origin and place.
    @Test func aScriptCannotShadowTheDocumentCheck() async throws {
        let page = try await FramePage.load()
        let gate = Self.gate()
        let child = try #require(page.frame(path: "/child"))
        _ = try await gate.callAsyncJavaScript("return 1", arguments: [:], in: page.webView, frame: child, contentWorld: .page)
        let origin = try #require(try await page.run("return location.origin", in: child) as? String)
        _ = try await page.run("document.getElementById('a').src = 'cmux-test://blocked.test/moved'; return true", in: page.main)
        _ = try await FramePage.settle(page.webView) { frames in
            frames.contains { $0.url == "cmux-test://blocked.test/moved" }
        }
        // The blocked page's own script.
        _ = try await page.webView.callAsyncJavaScript(
            """
            for (const [name, value] of [["origin", origin], ["protocol", "cmux-test:"], ["host", "allowed.test"]]) {
              Object.defineProperty(Function.prototype, name, { get: () => value, configurable: true });
            }
            return true
            """,
            arguments: ["origin": origin], in: child.info, contentWorld: .page
        )
        let error = await Self.error {
            try await gate.callAsyncJavaScript(
                "function location() {}\nwindow.__ranByGate = true; return document.body.innerText",
                arguments: [:],
                in: page.webView,
                frame: child,
                contentWorld: .page
            )
        }
        #expect(error?.code == "blocked", "the blocked frame was read past a shadowed check: \(String(describing: error))")
        let ran = try await page.run("return window.__ranByGate === true", in: child)
        #expect(ran as? Bool == false, "the script ran in the blocked document")
    }

    /// Mouse input at a point over a blocked frame would reach it; points
    /// elsewhere on the page are fine.
    @Test func pointerInputOverAFrameThatShowsABlockedPageIsRefused() async throws {
        let page = try await FramePage.load()
        let gate = Self.gate()
        let over = await Self.error { try await gate.checkPointer(at: [CGPoint(x: 250, y: 50)], in: page.webView, frames: page.frames) }
        #expect(over?.code == "blocked", "a point over the blocked frame was allowed")
        let path = await Self.error {
            try await gate.checkPointer(at: [CGPoint(x: 50, y: 50), CGPoint(x: 240, y: 30)], in: page.webView, frames: page.frames)
        }
        #expect(path?.code == "blocked", "a drag ending over the blocked frame was allowed")
        #expect(await Self.error { try await gate.checkPointer(at: [CGPoint(x: 50, y: 50)], in: page.webView, frames: page.frames) } == nil)
        #expect(await Self.error { try await gate.checkPointer(at: [CGPoint(x: 350, y: 250)], in: page.webView, frames: page.frames) } == nil)
    }

    /// Keys and inserted text go to the focused frame.
    @Test func keyboardInputWhileABlockedFrameHasTheFocusIsRefused() async throws {
        let page = try await FramePage.load()
        let gate = Self.gate()
        let blocked = try #require(page.frame(host: "blocked.test"))
        let allowed = try #require(page.frame(path: "/child"))
        #expect(await Self.error { try await gate.checkFocus(in: page.webView, frames: page.frames) } == nil)
        _ = try await page.run("document.getElementById('f').focus(); return document.activeElement.id", in: blocked)
        let error = await Self.error { try await gate.checkFocus(in: page.webView, frames: page.frames) }
        #expect(error?.code == "blocked", "typing into the blocked frame's field was allowed")
        _ = try await page.run("document.getElementById('f').focus(); return document.activeElement.id", in: allowed)
        #expect(await Self.error { try await gate.checkFocus(in: page.webView, frames: page.frames) } == nil,
                "focus moved to the allowed frame, yet typing was refused")
    }

    /// A screenshot or PDF of the tab would show the blocked frame.
    @Test func capturesOfATabThatShowsABlockedFrameAreRefused() async throws {
        let page = try await FramePage.load()
        let error = await Self.error { try Self.gate().checkCapture(in: page.webView, frames: page.frames) }
        #expect(error?.code == "blocked", "a capture of the blocked frame was allowed")
        let unrelated = Self.gate(prohibiting: "cmux-test://other.test")
        #expect(await Self.error { try unrelated.checkCapture(in: page.webView, frames: page.frames) } == nil)
    }

    /// A blocked frame (an ad or tracker iframe under `allowedDomains`) must
    /// not refuse every capture of the tab: the capture blanks that frame's
    /// box and shows the rest of the page.
    @Test func aScreenshotBlanksABlockedFrameAndShowsTheRest() async throws {
        let page = try await FramePage.load()
        let blocked = try #require(page.frame(host: "blocked.test"))
        let allowed = try #require(page.frame(path: "/child"))
        _ = try await page.run("document.body.style.background = 'rgb(255, 0, 0)'; return true", in: blocked)
        _ = try await page.run("document.body.style.background = 'rgb(0, 255, 0)'; return true", in: allowed)
        let gate = Self.gate()
        let image = try await gate.coverBlockedFrames(in: page.webView, frames: { await BrowserReplFrame.readTree(of: page.webView) }) {
            (try await FramePage.viewportImage(of: page.webView), CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        let blockedPixel = try #require(FramePage.pixel(image, x: 250, y: 50))
        #expect(!(blockedPixel.red > 0.8 && blockedPixel.green < 0.2), "the blocked frame's content is in the capture")
        let allowedPixel = try #require(FramePage.pixel(image, x: 60, y: 50))
        #expect(allowedPixel.green > 0.8 && allowedPixel.red < 0.2, "the allowed frame was blanked too")
    }

    /// The capture mask found a child frame whose marked document is
    /// blocked although the tree's record of it is not (it navigated after
    /// the tree was read): the screenshot blanks it too.
    @Test func aScreenshotBlanksAFrameTheMaskFoundBlocked() async throws {
        let page = try await FramePage.load()
        let allowed = try #require(page.frame(path: "/child"))
        _ = try await page.run("document.body.style.background = 'rgb(0, 255, 0)'; return true", in: allowed)
        let gate = Self.gate(prohibiting: "cmux-test://other.test")
        let image = try await gate.coverBlockedFrames(
            in: page.webView,
            frames: { await BrowserReplFrame.readTree(of: page.webView) },
            blockedChildFrames: [allowed.frameID: "blocked by test"]
        ) {
            (try await FramePage.viewportImage(of: page.webView), CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        let pixel = try #require(FramePage.pixel(image, x: 60, y: 50))
        #expect(!(pixel.green > 0.8 && pixel.red < 0.2), "the frame the mask found blocked is in the capture")
    }

    /// A frame the capture mask found blocked that the screenshot cannot
    /// find in the tree cannot be blanked, so the screenshot is refused.
    @Test func aFrameTheMaskFoundBlockedThatTheTreeLacksRefusesTheScreenshot() async throws {
        let page = try await FramePage.load()
        let gate = Self.gate(prohibiting: "cmux-test://other.test")
        let error = await Self.error {
            try await gate.coverBlockedFrames(
                in: page.webView,
                frames: { await BrowserReplFrame.readTree(of: page.webView) },
                blockedChildFrames: ["999999999": "blocked by test"]
            ) {
                (try await FramePage.viewportImage(of: page.webView), CGRect(x: 0, y: 0, width: 400, height: 300))
            }
        }
        #expect(error?.code == "blocked", "a capture with a blocked frame it could not find was allowed")
    }

    /// Blanking a box hides a frame only when nothing draws its content
    /// elsewhere; a reflection does, so the capture is refused.
    @Test func aScreenshotOfABlockedFrameDrawnOutsideItsBoxIsRefused() async throws {
        let page = try await FramePage.load()
        _ = try await page.run("document.getElementById('b').style.webkitBoxReflect = 'below 0px'; return true", in: page.main)
        let gate = Self.gate()
        let error = await Self.error {
            try await gate.coverBlockedFrames(in: page.webView, frames: { await BrowserReplFrame.readTree(of: page.webView) }) {
                (try await FramePage.viewportImage(of: page.webView), CGRect(x: 0, y: 0, width: 400, height: 300))
            }
        }
        #expect(error?.code == "blocked", "a capture of a reflected blocked frame was allowed")
    }

    /// A file chooser is answered with files only when its own frame is
    /// allowed; another frame of the tab that shows a blocked page does not
    /// matter.
    @Test func aFileChooserIsJudgedByItsOwnFrame() async throws {
        let page = try await FramePage.load()
        let gate = Self.gate()
        let blocked = try #require(page.frame(host: "blocked.test")?.info)
        let allowed = try #require(page.frame(path: "/child")?.info)
        #expect(await Self.error { try await gate.checkFileChooser(frame: allowed, in: page.webView, frames: page.frames) } == nil,
                "a chooser in an allowed frame was refused because another frame is blocked")
        let error = await Self.error { try await gate.checkFileChooser(frame: blocked, in: page.webView, frames: page.frames) }
        #expect(error?.code == "blocked", "files were given to a chooser in a blocked frame")
    }

    /// The chooser's frame is judged by the document it shows now; when the
    /// frame tree read for the answer no longer has it (it went away, or its
    /// id could not be read), that document cannot be judged, so no files
    /// are given.
    @Test func aFileChooserWhoseFrameIsMissingFromTheTreeIsRefused() async throws {
        let page = try await FramePage.load()
        let gate = Self.gate()
        let allowed = try #require(page.frame(path: "/child")?.info)
        let withoutChild = page.frames.filter { $0.info !== allowed }
        let error = await Self.error { try await gate.checkFileChooser(frame: allowed, in: page.webView, frames: withoutChild) }
        #expect(error != nil, "files were given to a chooser whose frame the tree no longer has")
        let main = try #require(page.frames.first?.info)
        let noMain = await Self.error { try await gate.checkFileChooser(frame: main, in: page.webView, frames: []) }
        #expect(noMain != nil, "files were given to a main-frame chooser without a frame tree")
    }

    /// A chooser is answered only into the document that opened it: when its
    /// frame shows another document by the answer (here one the policy
    /// allows too), no files are given, with a policy or without one.
    @Test(arguments: [true, false])
    func aFileChooserWhoseFrameNavigatedSinceIsStale(underPolicy: Bool) async throws {
        let page = try await FramePage.load()
        let gate = underPolicy ? Self.gate() : BrowserReplFrameGate(world: Self.world)
        let recorded = try #require(page.frame(path: "/child")?.info)
        #expect(await Self.error { try await gate.checkFileChooser(frame: recorded, in: page.webView, frames: page.frames) } == nil)
        _ = try await page.run("document.getElementById('a').src = 'cmux-test://allowed.test/next'; return true", in: page.main)
        let frames = try await FramePage.settle(page.webView) { frames in
            frames.contains { $0.url == "cmux-test://allowed.test/next" }
        }
        let error = await Self.error { try await gate.checkFileChooser(frame: recorded, in: page.webView, frames: frames) }
        #expect(error?.code == "stale", "files were given to a chooser whose frame shows another document: \(String(describing: error))")
    }

    /// A refusal names the blocked frame, which the session may not read:
    /// its URL reaches the session as frames.list gives it to any reader
    /// (``BrowserReplPageURL`` with no creator), never with the credential
    /// values in it.
    @Test func aRefusalNamesABlockedFrameWithoutTheCredentialsInItsURL() async throws {
        let html = """
            <iframe id=a src="cmux-test://allowed.test/child" style="position:absolute;left:10px;top:10px;width:100px;height:80px;border:0"></iframe>
            <iframe id=b src="cmux-test://blocked.test/x?access_token=T0KEN&page=2" style="position:absolute;left:200px;top:10px;width:100px;height:80px;border:0"></iframe>
            """
        let page = try await FramePage.load(html: html) { frames in frames.count >= 3 && frames.allSatisfy { !$0.url.isEmpty } }
        let gate = Self.gate()
        let blocked = try #require(page.frame(host: "blocked.test"))
        try #require(blocked.url.contains("T0KEN"))
        _ = try await page.run("document.getElementById('f').focus(); return true", in: blocked)
        let refusals = [
            await Self.error { try await gate.checkPointer(at: [CGPoint(x: 250, y: 50)], in: page.webView, frames: page.frames) },
            await Self.error { try await gate.checkFocus(in: page.webView, frames: page.frames) },
            await Self.error { try gate.checkCapture(in: page.webView, frames: page.frames) },
        ]
        for refusal in refusals {
            let refusal = try #require(refusal)
            #expect(refusal.code == "blocked")
            #expect(!refusal.message.contains("T0KEN"), "a refusal named the blocked frame with its credential: \(refusal.message)")
            #expect(refusal.message.contains("blocked.test/x"), "a refusal no longer names the frame: \(refusal.message)")
        }
    }

    /// `window.frames` leaves out frames in shadow trees, so a child's index
    /// in WebKit's frame tree is not its index there. A blocked frame in a
    /// shadow tree must still refuse a point over it.
    @Test func pointerInputOverABlockedFrameInAShadowTreeIsRefused() async throws {
        let html = """
            <iframe id=a src="cmux-test://allowed.test/child" style="position:absolute;left:10px;top:10px;width:100px;height:80px;border:0"></iframe>
            <div id=host></div>
            <script>
            const root = document.getElementById('host').attachShadow({ mode: 'closed' });
            root.innerHTML = '<iframe src="cmux-test://blocked.test/x" style="position:absolute;left:200px;top:10px;width:100px;height:80px;border:0"></iframe>';
            </script>
            <iframe id=c src="cmux-test://allowed.test/other" style="position:absolute;left:10px;top:150px;width:100px;height:80px;border:0"></iframe>
            """
        let page = try await FramePage.load(html: html) { frames in frames.count >= 4 && frames.allSatisfy { !$0.url.isEmpty } }
        let gate = Self.gate()
        let over = await Self.error { try await gate.checkPointer(at: [CGPoint(x: 250, y: 50)], in: page.webView, frames: page.frames) }
        #expect(over?.code == "blocked", "a point over a blocked frame in a shadow tree was allowed")
    }

    /// In a tab the session created the policy's content rules stop a
    /// blocked frame from loading; the empty frame left behind is the
    /// parent's and does not refuse the tab.
    @Test func aFrameTheContentRulesKeptFromLoadingDoesNotRefuseTheTab() async throws {
        let gate = Self.gate()
        let rules = String(decoding: try JSONSerialization.data(withJSONObject: gate.policy.contentRules), as: UTF8.self)
        let store = try #require(WKContentRuleListStore.default())
        let identifier = "cmux-frame-gate-tests-\(UUID().uuidString)"
        let list = try #require(try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: rules))
        defer { store.removeContentRuleList(forIdentifier: identifier) { _ in } }
        // The blocked frame never gets a URL; the allowed one loads.
        let page = try await FramePage.load(loaded: { frames in frames.contains { $0.url.hasSuffix("/child") } }) { configuration in
            configuration.userContentController.add(list)
        }
        #expect(page.frame(host: "blocked.test") == nil, "the content rules let the blocked frame load")
        #expect(await Self.error { try gate.checkCapture(in: page.webView, frames: page.frames) } == nil)
        #expect(await Self.error { try await gate.checkPointer(at: [CGPoint(x: 250, y: 50)], in: page.webView, frames: page.frames) } == nil)
    }

    // MARK: Incomplete frame trees

    /// WebKit's frame tree can come back without some frames (no `_frames:`,
    /// a child it could not describe): a blocked frame missing from it would
    /// look like no blocked frame at all. The gate fails closed instead: a
    /// tree that has fewer child frames than the main document refuses
    /// input and captures with `stale`.
    @Test func aTreeReadThatLostFramesRefusesInputAndCaptures() async throws {
        let page = try await FramePage.load()
        let gate = Self.gate()
        let blocked = try #require(page.frame(host: "blocked.test"))
        _ = try await page.run("document.getElementById('f').focus(); return document.activeElement.id", in: blocked)
        let partial = page.frames.filter { $0.frameID != blocked.frameID }
        for (name, frames) in [("without the blocked frame", partial), ("main frame only", [page.main])] {
            let pointer = await Self.error { try await gate.checkPointer(at: [CGPoint(x: 250, y: 50)], in: page.webView, frames: frames) }
            #expect(pointer?.code == "stale", "\(name): a point over a frame the tree lost was allowed: \(String(describing: pointer))")
            let focus = await Self.error { try await gate.checkFocus(in: page.webView, frames: frames) }
            #expect(focus?.code == "stale", "\(name): typing while a frame the tree lost has the focus was allowed: \(String(describing: focus))")
            let input = await Self.error { try await gate.guardingInput(in: page.webView, frames: { frames }, checkFocusAfter: false) { true } }
            #expect(input?.code == "stale", "\(name): input was let through without guarding a frame the tree lost: \(String(describing: input))")
            let capture = await Self.error {
                try await gate.coverBlockedFrames(in: page.webView, frames: { frames }) {
                    (try await FramePage.viewportImage(of: page.webView), CGRect(x: 0, y: 0, width: 400, height: 300))
                }
            }
            #expect(capture?.code == "stale", "\(name): a screenshot showed a frame the tree lost: \(String(describing: capture))")
        }
        // The whole tree still passes where no blocked frame is in the way.
        #expect(await Self.error { try await gate.checkPointer(at: [CGPoint(x: 50, y: 50)], in: page.webView, frames: page.frames) } == nil)
    }

    /// Script in a world page or agent code reaches can traverse to a
    /// frame of its site that relaxes `document.domain`, so such a call is
    /// refused while a blocked frame of the site is in the tab. A tree read
    /// that lost that frame must not let the call through: it fails closed,
    /// as input and captures do.
    @Test func anEvaluateThatCouldReachAFrameTheTreeLostIsRefused() async throws {
        let html = """
            <iframe id=a src="cmux-test://a.site.test/child" style="position:absolute;left:10px;top:10px;width:100px;height:80px;border:0"></iframe>
            <iframe id=b src="cmux-test://blocked.site.test/x" style="position:absolute;left:200px;top:10px;width:100px;height:80px;border:0"></iframe>
            """
        let page = try await FramePage.load(url: "cmux-test://a.site.test/", html: html) { frames in
            frames.count >= 3 && frames.allSatisfy { !$0.url.isEmpty }
        }
        let gate = Self.gate(prohibiting: "cmux-test://blocked.site.test")
        let allowed = try #require(page.frame(host: "a.site.test"))
        let blocked = try #require(page.frame(host: "blocked.site.test"))
        let whole = await Self.error {
            try await gate.callAsyncJavaScript("return 1", arguments: [:], in: page.webView, frame: allowed, contentWorld: .page)
        }
        #expect(whole?.code == "blocked", "\(String(describing: whole))")
        let partial = page.frames.filter { $0.frameID != blocked.frameID }
        gate.frameTree = { _ in partial }
        let lost = await Self.error {
            try await gate.callAsyncJavaScript("return 1", arguments: [:], in: page.webView, frame: allowed, contentWorld: .page)
        }
        #expect(lost?.code == "stale", "script ran beside a blocked frame of its site the tree lost: \(String(describing: lost))")
    }

    // MARK: Probes that never answer

    /// The gate's own probes (the focus probe, the frame boxes, a frame's
    /// document) are bounded: one that does not answer refuses the call
    /// with `stale` instead of hanging every later input call.
    @Test func aProbeThatNeverAnswersRefusesWithStale() async throws {
        let page = try await FramePage.load()
        // The page's web process runs no other script for 25 s, so the
        // gate's probes of any frame in it do not answer (as when a
        // navigation replaces the document and WebKit drops the completion).
        Self.startBusyLoop(in: page.webView, seconds: 25)
        let gate = Self.gate()
        let blocked = try #require(page.frame(host: "blocked.test"))
        let webView = SendableBox(page.webView)
        let frames = SendableBox(page.frames)
        let focus = await browserReplWithDeadline(seconds: 30) { @MainActor in
            await Self.error { try await gate.checkFocus(in: webView.value, frames: frames.value) }
        }
        #expect(focus??.code == "stale", "the focus probe of a frame that does not answer hung or passed: \(String(describing: focus))")
        let pointer = await browserReplWithDeadline(seconds: 30) { @MainActor in
            await Self.error { try await gate.checkPointer(at: [CGPoint(x: 50, y: 50)], in: webView.value, frames: frames.value) }
        }
        #expect(pointer??.code == "stale", "the frame-box probe of a page that does not answer hung or passed: \(String(describing: pointer))")
        let frame = SendableBox(blocked)
        let document = await browserReplWithDeadline(seconds: 30) { @MainActor in
            await Self.error { try await gate.authorize(frame.value, in: webView.value) }
        }
        #expect(document??.code == "stale", "the document probe of a frame that does not answer hung or passed: \(String(describing: document))")
    }

    // MARK: Support

    /// Starts a loop of `seconds` in `webView`'s page before this returns
    /// (the request is sent now; nothing waits for its answer).
    static func startBusyLoop(in webView: WKWebView, seconds: Int) {
        webView.evaluateJavaScript("{ const end = Date.now() + \(seconds * 1000); while (Date.now() < end) {} }", completionHandler: nil)
    }

    static let world = WKContentWorld.world(name: "cmux-frame-gate-tests")

    static func gate(prohibiting pattern: String = "cmux-test://blocked.test") -> BrowserReplFrameGate {
        let gate = BrowserReplFrameGate(world: world)
        var policy = BrowserReplDomainPolicy()
        policy.prohibited = [try! BrowserReplDomainPattern.parse(pattern, title: "test")]
        gate.policy = policy
        return gate
    }

    static func error(_ body: () async throws -> Any?) async -> BrowserReplDriverError? {
        do {
            _ = try await body()
            return nil
        } catch let error as BrowserReplDriverError {
            return error
        } catch {
            return BrowserReplDriverError(code: "unexpected", message: "\(error)")
        }
    }
}

/// A page with two child frames: `allowed.test/child` at (10, 10) and
/// `blocked.test/x` at (200, 10), each 100 x 80 and holding a text field.
@MainActor
struct FramePage {
    let webView: WKWebView
    let frames: [BrowserReplFrame]

    /// The main frame as the driver names it without a tree read.
    var main: BrowserReplFrame {
        BrowserReplFrame(frameID: "main", parentFrameID: nil, indexInParent: 0, info: nil,
                         url: webView.url?.absoluteString ?? "", name: "", crossOrigin: false)
    }

    func frame(host: String) -> BrowserReplFrame? {
        frames.dropFirst().first { URL(string: $0.url)?.host == host }
    }

    func frame(path: String) -> BrowserReplFrame? {
        frames.dropFirst().first { URL(string: $0.url)?.path == path }
    }

    static let mainPage = """
        <p>main</p>
        <iframe id=a src="cmux-test://allowed.test/child" style="position:absolute;left:10px;top:10px;width:100px;height:80px;border:0"></iframe>
        <iframe id=b src="cmux-test://blocked.test/x" style="position:absolute;left:200px;top:10px;width:100px;height:80px;border:0"></iframe>
        """

    /// - Parameter loaded: when the page counts as loaded; by default once
    ///   every frame has a URL.
    static func load(
        url: String = "cmux-test://allowed.test/",
        html: String = mainPage,
        loaded: (([BrowserReplFrame]) -> Bool)? = nil,
        childPage: String? = nil,
        configure: (WKWebViewConfiguration) async throws -> Void = { _ in }
    ) async throws -> FramePage {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(FramePageSchemeHandler(mainPage: html, childPage: childPage), forURLScheme: "cmux-test")
        try await configure(configuration)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let expected = html == mainPage && url == "cmux-test://allowed.test/" ? 3 : 1
        webView.load(URLRequest(url: URL(string: url)!))
        let frames = try await settle(webView) { frames in
            frames.count >= expected && (loaded?(frames) ?? frames.allSatisfy { !$0.url.isEmpty })
        }
        return FramePage(webView: webView, frames: frames)
    }

    /// The frame tree once `done` holds for it (child frames load after the
    /// main frame).
    static func settle(_ webView: WKWebView, _ done: ([BrowserReplFrame]) -> Bool) async throws -> [BrowserReplFrame] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            let frames = await BrowserReplFrame.readTree(of: webView)
            if done(frames) { return frames }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw BrowserReplDriverError(code: "timeout", message: "the test page did not settle")
    }

    /// The viewport as an image of one pixel per CSS pixel.
    static func viewportImage(of webView: WKWebView) async throws -> CGImage {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        configuration.snapshotWidth = NSNumber(value: Double(webView.bounds.width))
        let image = try await webView.takeSnapshot(configuration: configuration)
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw BrowserReplDriverError(code: "invalid", message: "the snapshot had no bitmap")
        }
        return cgImage
    }

    /// The color at CSS pixel (`x`, `y`) from the top-left of `image`, which
    /// shows a 400-point-wide viewport.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> (red: CGFloat, green: CGFloat, blue: CGFloat)? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let scale = CGFloat(bitmap.pixelsWide) / 400
        guard let color = bitmap.colorAt(x: Int(CGFloat(x) * scale), y: Int(CGFloat(y) * scale))?.usingColorSpace(.deviceRGB) else {
            return nil
        }
        return (color.redComponent, color.greenComponent, color.blueComponent)
    }

    /// Runs `source` in `frame`'s page world without the gate.
    func run(_ source: String, in frame: BrowserReplFrame) async throws -> Any? {
        try await webView.callAsyncJavaScript(source, arguments: [:], in: frame.info, contentWorld: .page)
    }
}

final class FramePageSchemeHandler: NSObject, WKURLSchemeHandler {
    let mainPage: String
    /// A child page's own HTML after its `<p>host/path</p>`, if set.
    let childPage: String?

    init(mainPage: String, childPage: String? = nil) {
        self.mainPage = mainPage
        self.childPage = childPage
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let host = url.host ?? ""
        let html = url.path == "/" || url.path.isEmpty
            ? mainPage
            : "<p>\(host)\(url.path)</p>" + (childPage ?? "<input id=f>")
        task.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: -1, textEncodingName: "utf-8"))
        task.didReceive(Data(html.utf8))
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// Hands main-actor test values to a `@Sendable` closure that runs on the
/// main actor.
struct SendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// A call that started on a tab of the session's workspace can be
/// suspended in WebKit when the user moves the tab to another workspace.
/// The gate asks the tab capability again with the tab's workspace as it
/// is at each script and input step, so a moved tab is neither read nor
/// sent input.
@MainActor
@Suite("Frame gate: a tab moved to another workspace", .serialized)
struct BrowserReplFrameGateWorkspaceTests {
    @Test func aTabMovedToAnotherWorkspaceIsNeitherReadNorSentInput() async throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 200), configuration: WKWebViewConfiguration())
        webView.loadHTMLString("<p>page</p>", baseURL: URL(string: "https://example.com/"))
        let frames = try await FramePage.settle(webView) { $0.first?.url.hasPrefix("https://example.com") == true }
        let main = try #require(frames.first)
        let home = UUID()
        var tabWorkspace: UUID? = home
        let gate = BrowserReplFrameGate(world: BrowserReplFrameGateTests.world)
        gate.scope = { webView in
            .init(sessionID: "s", fileRoots: nil, tab: BrowserReplTabFacts(id: UUID(), mainFrameURL: webView.url, workspaceID: tabWorkspace), workspaceID: home)
        }
        let read = "return document.body.innerText"
        let text = try await gate.callAsyncJavaScript(read, arguments: [:], in: webView, frame: main, contentWorld: .page)
        #expect((text as? String)?.contains("page") == true)

        tabWorkspace = UUID()
        let error = await BrowserReplFrameGateTests.error {
            try await gate.callAsyncJavaScript("window.ran = 1; return document.body.innerText", arguments: [:], in: webView, frame: main, contentWorld: .page)
        }
        #expect(error?.code == "denied", "a tab moved to another workspace was read: \(String(describing: error))")
        #expect(try await webView.evaluateJavaScript("window.ran === undefined") as? Bool == true)

        var sent = false
        let inputError = await BrowserReplFrameGateTests.error {
            try await gate.guardingInput(in: webView, frames: { frames }, checkFocusAfter: false) { sent = true }
        }
        #expect(inputError?.code == "denied")
        #expect(!sent, "input reached a tab moved to another workspace")
    }
}

extension BrowserReplFrameGateWorkspaceTests {
    /// A read that was already running in the page when the user moved its
    /// tab to another workspace hands back nothing: the gate asks the tab
    /// capability again before it returns the script's result.
    @Test(arguments: [false, true])
    func aReadThatFinishesAfterItsTabMovedHandsBackNothing(policyActive: Bool) async throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 200), configuration: WKWebViewConfiguration())
        webView.loadHTMLString("<p>secret page</p>", baseURL: URL(string: "https://example.com/"))
        let frames = try await FramePage.settle(webView) { $0.first?.url.hasPrefix("https://example.com") == true }
        let main = try #require(frames.first)
        let home = UUID()
        var tabWorkspace: UUID? = home
        let gate = BrowserReplFrameGate(world: BrowserReplFrameGateTests.world)
        if policyActive {
            var policy = BrowserReplDomainPolicy()
            policy.prohibited = [try BrowserReplDomainPattern.parse("blocked.test", title: "test")]
            gate.policy = policy
        }
        gate.scope = { webView in
            .init(sessionID: "s", fileRoots: nil, tab: BrowserReplTabFacts(id: UUID(), mainFrameURL: webView.url, workspaceID: tabWorkspace), workspaceID: home)
        }
        let read = Task { @MainActor in
            await BrowserReplFrameGateTests.error {
                _ = try await gate.callAsyncJavaScript(
                    "await new Promise((resolve) => { window.release = resolve; }); return document.body.innerText",
                    arguments: [:], in: webView, frame: main, contentWorld: .page
                )
            }
        }
        var suspended = false
        for _ in 0..<2000 where !suspended {
            suspended = try await webView.evaluateJavaScript("typeof window.release === 'function'") as? Bool == true
            if !suspended { await Task.yield() }
        }
        try #require(suspended, "the read never reached the page")
        tabWorkspace = UUID()
        _ = try await webView.evaluateJavaScript("window.release(); true")
        let error = await read.value
        #expect(error?.code == "denied", "a read finished after its tab moved to another workspace handed back its result: \(String(describing: error))")
    }
}

/// A call whose cell timed out or whose session was reset is cancelled
/// while it may still wait in WebKit between native steps. Every native
/// input step asks the gate's tab check first, so a cancelled call sends
/// nothing more: the check refuses it, and so does the input guard.
@MainActor
@Suite("Frame gate: a cancelled call", .serialized)
struct BrowserReplFrameGateCancellationTests {
    @Test func aCancelledCallSendsNoMoreInput() async throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 200), configuration: WKWebViewConfiguration())
        webView.loadHTMLString("<p>page</p>", baseURL: URL(string: "https://example.com/"))
        let frames = try await FramePage.settle(webView) { $0.first?.url.hasPrefix("https://example.com") == true }
        let gate = BrowserReplFrameGate(world: BrowserReplFrameGateTests.world)
        let home = UUID()
        gate.scope = { webView in
            .init(sessionID: "s", fileRoots: nil, tab: BrowserReplTabFacts(id: UUID(), mainFrameURL: webView.url, workspaceID: home), workspaceID: home)
        }
        #expect(await BrowserReplFrameGateTests.error { try gate.checkTab(in: webView) } == nil)

        var sent = false
        let call = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            let step = await BrowserReplFrameGateTests.error { try gate.checkTab(in: webView) }
            let input = await BrowserReplFrameGateTests.error {
                try await gate.guardingInput(in: webView, frames: { frames }, checkFocusAfter: false) { sent = true }
            }
            return (step, input)
        }
        let (step, input) = await call.value
        #expect(step?.code == "cancelled", "\(String(describing: step))")
        #expect(input?.code == "cancelled", "\(String(describing: input))")
        #expect(!sent, "a cancelled call sent input")
    }
}

/// A multi-event input (`input.drag`) sends its press, moves and release
/// as separate native events, and each asks the gate's tab check first.
/// The page can navigate its main frame between two of them (the child
/// frame hold does not cover the main frame), so while guarded input is in
/// flight that check also judges the main frame's live page: a blocked
/// page, or a document of another origin than the one the input's checks
/// and guards judged, gets no further event.
@MainActor
@Suite("Frame gate: a main frame that navigates during input", .serialized)
struct BrowserReplFrameGateMainFrameNavigationTests {
    /// The tab check of the next native step after the main frame left for
    /// `destination`, inside guarded input.
    private func stepAfterMainFrameNavigates(to destination: String) async throws -> BrowserReplDriverError? {
        let page = try await FramePage.load()
        let gate = BrowserReplFrameGateTests.gate()
        let host = try #require(URL(string: destination)?.host)
        var before: BrowserReplDriverError?
        var after: BrowserReplDriverError?
        _ = await BrowserReplFrameGateTests.error {
            try await gate.guardingInput(in: page.webView, frames: { page.frames }, checkFocusAfter: false) {
                before = await BrowserReplFrameGateTests.error { try gate.checkTab(in: page.webView) }
                _ = try await page.webView.evaluateJavaScript("location.href = \"\(destination)\"; true")
                // WebKit names the new page from the navigation's start, before it commits.
                _ = try await FramePage.settle(page.webView) { _ in page.webView.url?.host == host }
                after = await BrowserReplFrameGateTests.error { try gate.checkTab(in: page.webView) }
                return nil
            }
        }
        #expect(before == nil, "the step before the navigation was refused: \(String(describing: before))")
        return after
    }

    @Test func aMainFrameThatNavigatesToABlockedPageGetsNoFurtherStep() async throws {
        let error = try await stepAfterMainFrameNavigates(to: "cmux-test://blocked.test/")
        #expect(error?.code == "blocked", "a step of the input reached the blocked page: \(String(describing: error))")
    }

    @Test func aMainFrameThatNavigatesToAnotherOriginGetsNoFurtherStep() async throws {
        let error = try await stepAfterMainFrameNavigates(to: "cmux-test://other.test/")
        #expect(error?.code == "stale", "a step of the input reached a document its checks never judged: \(String(describing: error))")
    }

    /// Outside guarded input the tab check judges the tab alone, as before.
    @Test func outsideInputTheTabCheckDoesNotJudgeThePage() async throws {
        let page = try await FramePage.load(url: "cmux-test://blocked.test/")
        #expect(await BrowserReplFrameGateTests.error { try BrowserReplFrameGateTests.gate().checkTab(in: page.webView) } == nil)
    }
}
