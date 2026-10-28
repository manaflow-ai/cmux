import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextHibernation
import CmuxNextSettings
import Foundation
import Testing

/// Feature `memoryDiscardCrashedSubframes`: a page whose out-of-process frame crashed is
/// discarded while hidden, or at its next hide, as Chrome's DiscardPageWithCrashedSubframePolicy does
/// (chrome/browser/performance_manager/policies/discard_page_with_crashed_subframe_policy.cc, at the crash
/// and at OnIsVisibleChanged), so it reloads whole when shown and its renderers' memory goes; a shown page
/// keeps its sad frame. cmux starts that discard, so everything that keeps a page from cmux's own discards
/// (the lead rule, `beforeunload`, the person's pins and choices) keeps it from this one. CEF tells a browser
/// only of its main frame's renderer, so the shim reports each other frame's renderer (SUBFRAME_RENDERER)
/// and the child monitor names the browsers a renderer's end leaves a sad frame in. Against a spy shim for
/// the Chromium half and real WebKit pages for the hibernation half.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct CrashedSubframeDiscardTests {
    // MARK: The renderers of each page's other frames

    /// An ad iframe added long after the page's last load phase: its renderer's end still names the page.
    @Test func aFrameAddedLateCountsForItsRenderersEnd() {
        var renderers = CEFSubframeRenderers()
        renderers.attached("9-ad", client: 9, browser: 7)
        #expect(renderers.ended(client: 9) == [7])
        #expect(renderers.ended(client: 9).isEmpty, "a relaunched renderer of the same host remembered its old frames")
    }

    /// A frame removed (or moved to another site's renderer) while its renderer ran: that renderer's later
    /// crash, now hosting only other pages' frames, is no crash of this page.
    @Test func aFrameRemovedBeforeItsRendererCrashedDoesNotCount() {
        var renderers = CEFSubframeRenderers()
        renderers.attached("9-ad", client: 9, browser: 7)
        renderers.attached("9-embed", client: 9, browser: 8)
        renderers.detached("9-ad", client: 9, browser: 7, rendererExiting: false)
        #expect(renderers.ended(client: 9) == [8])
    }

    /// Chromium detaches a dead renderer's frames when it hears of the death, which can come before the
    /// child monitor's exit event: a frame its renderer's death detached still counts.
    @Test func aFrameTheRenderersDeathDetachedStillCounts() {
        var renderers = CEFSubframeRenderers()
        renderers.attached("9-ad", client: 9, browser: 7)
        renderers.detached("9-ad", client: 9, browser: 7, rendererExiting: true)
        #expect(renderers.ended(client: 9) == [7])
        #expect(renderers.ended(client: 9).isEmpty)
    }

    /// One of two frames of a page in a renderer goes: the other still names the page.
    @Test func aPageKeepsItsRendererWhileAnyOfItsFramesIsThere() {
        var renderers = CEFSubframeRenderers()
        renderers.attached("9-a", client: 9, browser: 7)
        renderers.attached("9-b", client: 9, browser: 7)
        renderers.detached("9-a", client: 9, browser: 7, rendererExiting: false)
        #expect(renderers.ended(client: 9) == [7])
    }

    @Test func aRendererProcessIsExitingOnlyOnceItEnds() {
        #expect(!CEFChildProcessMonitor.isExiting(getpid()), "the running app counted as exiting")
        #expect(CEFChildProcessMonitor.isExiting(0x7FFF_FFF0), "a pid no process has counted as running")
    }

    @Test func theShimReportsEachSubframesRenderer() {
        #expect(CEFShimEvent(kind: 64, browser: 7, request: 9, a: 1, b: 0, s1: "9-ab", s2: "")
            == .subframeRenderer(browser: 7, frame: "9-ab", client: 9, attached: true))
        #expect(CEFShimEvent(kind: 64, browser: 7, request: 9, a: 0, b: 0, s1: "9-ab", s2: "")
            == .subframeRenderer(browser: 7, frame: "9-ab", client: 9, attached: false))
    }

    // MARK: The Chromium tab hears its subframe's crash

    @Test func aCrashedOutOfProcessFrameReportsItsPage() throws {
        let rig = try ChromiumRig()
        rig.runtime.childExited(Self.renderer(pid: 900, client: 9, status: SIGSEGV, browsers: [7]))
        #expect(rig.crashes == 1, "the page did not hear its out-of-process frame crash")
    }

    @Test func theMainFramesRendererEndIsNoSubframeCrash() throws {
        let rig = try ChromiumRig()
        rig.runtime.childExited(Self.renderer(pid: ChromiumRig.mainPID, client: 3, status: SIGSEGV, browsers: [7]))
        #expect(rig.crashes == 0, "the main frame's crash (the sad tab) counted as a subframe's")
    }

    @Test func aRendererWithNoFrameOfThePageIsNotItsCrash() throws {
        let rig = try ChromiumRig()
        rig.runtime.childExited(Self.renderer(pid: 901, client: 12, status: SIGSEGV, browsers: [8]))
        #expect(rig.crashes == 0, "another page's renderer crash reached this page")
    }

    @Test func aNormalRendererExitIsNoCrash() throws {
        let rig = try ChromiumRig()
        rig.runtime.childExited(Self.renderer(pid: 900, client: 9, status: 0, browsers: [7]))
        #expect(rig.crashes == 0, "a renderer Chromium let go counted as a crash")
    }

    @Test func theHelperIdentityCarriesTheRendererClientID() {
        let identity = CEFHelperIdentity.parse(["Helper (Renderer)", "--type=renderer", "--renderer-client-id=42"])
        #expect(identity?.rendererClientID == 42)
        #expect(ChromiumHelperProcess.classify(["--type=renderer", "--renderer-client-id=42"]) == .renderer(clientID: 42))
        #expect(CEFHelperIdentity.parse(["--type=gpu-process"])?.rendererClientID == nil)
    }

    // MARK: The discard is cmux's own: the rules that keep a page from it

    /// What keeps a page from the timeout's discard keeps it from this one; the person's Hibernate Tab
    /// (external) is the only discard they let through.
    @Test func theLeadRuleAndThePersonsChoicesKeepAPageWithACrashedFrame() {
        let planner = ContentDiscardPlanner()
        let excluding = BrowserHibernationSetting(mode: .moderate, exclusions: ["example.com"])
        let facts: [(CannotDiscardReason, (inout ContentDiscardPlanner.Candidate) -> Void)] = [
            (.audio, { $0.isAudible = true }),
            (.capturing, { $0.isCapturing = true }),
            (.formInput, { $0.hasFormInput = true }),
            (.downloading, { $0.isDownloading = true }),
            (.beforeUnload, { $0.asksBeforeUnload = true }),
            (.agentLease, { $0.hasAgentLease = true }),
            (.pinned, { $0.isPinned = true }),
            (.excluded, { $0.host = "example.com" }),
        ]
        for (reason, apply) in facts {
            var page = ContentDiscardPlanner.Candidate(key: "p", hiddenFor: 60)
            apply(&page)
            let eligibility = planner.eligibility(of: page, setting: excluding, for: .crashedSubframe)
            #expect(eligibility.result == .protected, "\(reason)")
            #expect(eligibility.reason == reason)
        }
        let off = ContentDiscardPlanner.Candidate(key: "p", hiddenFor: 60)
        #expect(planner.eligibility(of: off, setting: BrowserHibernationSetting(mode: .off), for: .crashedSubframe).reason == .disabled)
    }

    // MARK: The hibernation discards a hidden page, never a shown one

    @Test func aCrashedSubframeDiscardsAHiddenTab() async throws {
        let rig = try Self.hibernationRig(feature: true)
        defer { rig.close() }
        let key = try await rig.hide(rig.page("hidden", body: "<p>hidden</p>"))
        #expect(!rig.hibernation.probing.contains(key), "the page was due before the crash")

        rig.hibernation.subframeDidCrash(key)
        try await rig.until("the hidden tab was discarded") { rig.isHibernated(key) || rig.exemption(key) != nil }
        #expect(rig.isHibernated(key), "kept: \(String(describing: rig.exemption(key)))")
    }

    @Test func aCrashedSubframeLeavesAShownTabAlone() async throws {
        let rig = try Self.hibernationRig(feature: true)
        defer { rig.close() }
        let key = try await rig.show(rig.page("shown", body: "<p>shown</p>"))

        rig.hibernation.subframeDidCrash(key)
        #expect(!rig.hibernation.probing.contains(key), "a shown tab started a discard")
        #expect(!rig.isHibernated(key))
    }

    /// The person saw the sad frame and switched away: the page goes at its hide, as Chrome's policy
    /// discards on the visibility change.
    @Test func aTabWhoseFrameCrashedWhileShownIsDiscardedWhenHidden() async throws {
        let rig = try Self.hibernationRig(feature: true)
        defer { rig.close() }
        let key = try await rig.show(rig.page("seen", body: "<p>seen</p>"))
        rig.hibernation.subframeDidCrash(key)
        #expect(!rig.isHibernated(key), "a shown tab was discarded")

        rig.services.cache.withdraw(key, by: rig.pane)
        try #require(rig.services.cache.phase(of: key) == .mountedHidden)
        try await rig.until("the hidden tab was discarded") { rig.isHibernated(key) || rig.exemption(key) != nil }
        #expect(rig.isHibernated(key), "kept: \(String(describing: rig.exemption(key)))")
    }

    /// A reload or a navigation replaced the document with the crashed frame: its hide discards nothing.
    @Test func aNewDocumentDropsTheCrashedFrame() async throws {
        let rig = try Self.hibernationRig(feature: true)
        defer { rig.close() }
        let page = try await rig.page("before", body: "<p>before</p>")
        let key = try await rig.show(page)
        rig.hibernation.subframeDidCrash(key)
        try await rig.navigate(page, to: "after")

        rig.services.cache.withdraw(key, by: rig.pane)
        try #require(rig.services.cache.phase(of: key) == .mountedHidden)
        #expect(!rig.hibernation.probing.contains(key), "a new document's hide started a discard")
        #expect(rig.hibernation.crashedSubframes[key] == nil)
        #expect(!rig.isHibernated(key))
    }

    @Test func aHiddenTabWithFormInputKeepsItsPage() async throws {
        let rig = try Self.hibernationRig(feature: true)
        defer { rig.close() }
        let page = try await rig.page("typed", body: "<input id='note'>")
        try await rig.typeInField("note", page)
        let key = try await rig.hide(page)

        rig.hibernation.subframeDidCrash(key)
        try await rig.until("the page was discarded or kept") { rig.isHibernated(key) || rig.exemption(key) != nil }
        #expect(rig.exemption(key) == .formInput, "a page with the person's typing was discarded")
        #expect(!rig.isHibernated(key))
    }

    @Test func aPinnedHiddenTabKeepsItsPage() async throws {
        let rig = try Self.hibernationRig(feature: true)
        defer { rig.close() }
        let key = try await rig.hide(rig.page("pinned", body: "<p>pinned</p>"))
        rig.hibernation.isPinned = { $0 == key }

        rig.hibernation.subframeDidCrash(key)
        try await rig.until("the page was discarded or kept") { rig.isHibernated(key) || rig.exemption(key) != nil }
        #expect(rig.exemption(key) == .pinned, "a pinned tab was discarded")
        #expect(!rig.isHibernated(key))
    }

    @Test func aHiddenTabAnAgentHoldsKeepsItsPage() async throws {
        let rig = try Self.hibernationRig(feature: true)
        defer { rig.close() }
        let key = try await rig.hide(rig.page("leased", body: "<p>leased</p>"))
        rig.hibernation.noteLease(key, held: true)

        rig.hibernation.subframeDidCrash(key)
        try await rig.until("the page was discarded or kept") { rig.isHibernated(key) || rig.exemption(key) != nil }
        #expect(rig.exemption(key) == .agentLease, "a tab an agent holds was discarded")
        #expect(!rig.isHibernated(key))
    }

    @Test func withHibernationOffAHiddenTabKeepsItsCrashedFrame() async throws {
        let rig = try Self.hibernationRig(feature: true)
        defer { rig.close() }
        let key = try await rig.hide(rig.page("off", body: "<p>off</p>"))
        rig.hibernation.apply(BrowserHibernationSetting(mode: .off))

        rig.hibernation.subframeDidCrash(key)
        #expect(!rig.hibernation.probing.contains(key), "hibernation is off, yet the tab started a discard")
        #expect(!rig.isHibernated(key))
    }

    @Test func withTheFeatureOffAHiddenTabKeepsItsCrashedFrame() async throws {
        let rig = try Self.hibernationRig(feature: false)
        defer { rig.close() }
        let key = try await rig.hide(rig.page("featureoff", body: "<p>off</p>"))
        rig.hibernation.subframeDidCrash(key)
        #expect(!rig.hibernation.probing.contains(key), "the feature is off, yet the tab started a discard")
        #expect(!rig.isHibernated(key))
    }

    @Test func aMountedChromiumPageReportsToTheHibernationOnlyWithTheFeatureOn() throws {
        let chromium = try ChromiumRig(follows: false)
        for feature in [false, true] {
            let rig = try Self.hibernationRig(feature: feature)
            defer { rig.close() }
            chromium.tab.onSubframeCrash = nil
            rig.hibernation.pageDidMount("chromium", chromium.tab)
            #expect((chromium.tab.onSubframeCrash != nil) == feature, "feature \(feature): the hook is \(chromium.tab.onSubframeCrash != nil)")
        }
    }

    // MARK: Rigs

    /// A renderer's end as the child monitor reports it, with the browsers whose other frames it hosted.
    static func renderer(pid: Int32, client: Int32, status: Int32, browsers: Set<Int32>) -> CEFChildProcessMonitor.Exit {
        CEFChildProcessMonitor.Exit(pid: pid, processType: "renderer", subType: nil, isExtension: false, status: status,
                                    rendererClientID: client, subframeBrowsers: browsers)
    }

    /// The app's hibernation over real WebKit pages at normal pressure with a long timeout, so a hidden
    /// page goes only through the crash.
    static func hibernationRig(feature: Bool) throws -> HiddenPageHibernationTests.Rig {
        let rig = try HiddenPageHibernationTests.Rig()
        rig.hibernation.pressureDidChange(.normal)
        rig.hibernation.apply(BrowserHibernationSetting(mode: .minutes(60), freezeSeconds: nil))
        rig.hibernation.discardsCrashedSubframes = feature
        return rig
    }

    /// A ready in-process runtime over ``CrashedSubframeShim`` with one tab, browser 7, whose main frame is in
    /// renderer pid ``mainPID``; `follows` sets its hook.
    @MainActor final class ChromiumRig {
        nonisolated static let mainPID = CrashedSubframeShim.mainPID
        let runtime: CEFRuntime
        let tab: CEFTab
        private(set) var crashes = 0

        init(follows: Bool = true) throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "cef-subframe-crash-\(UUID().uuidString)", directoryHint: .isDirectory)
            runtime = CEFRuntime(shim: try CrashedSubframeShim.library(), storage: CEFProfileStorage(root: root))
            // A pane's scheduled work reads the runtime through an unowned reference: it outlives the test.
            _ = Unmanaged.passRetained(runtime)
            let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
            host.endOfTurn = { $0() }
            tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(tab)
            runtime.register(tab, browser: 7)
            if follows { tab.onSubframeCrash = { [weak self] in self?.crashes += 1 } }
        }
    }
}

extension HiddenPageHibernationTests.Rig {
    /// Installs `page` as a tab's content and shows it in the pane.
    func show(_ page: WebKitTab) async throws -> String {
        let key = page.id.rawValue
        keys.append(key)
        services.cache.install(page, for: key)
        services.cache.present(key, by: pane, presence: .visible)
        try #require(services.cache.phase(of: key) == .mountedVisible)
        return key
    }

    /// Types `text` into field `id` as the person would; the page leaves the window after.
    func typeInField(_ id: String, _ page: WebKitTab, text: String = "draft") async throws {
        window.contentView = page.contentView
        window.makeFirstResponder(page.webView)
        _ = try await page.evaluate("document.getElementById('\(id)').focus(); true", world: .page, gesture: .agent)
        page.webView.insertText(text)
        try await until("the typing reached the page") {
            (try? await page.evaluate("document.getElementById('\(id)').value", world: .page, gesture: .agent)) == .string(text)
        }
        window.contentView = nil
    }

    /// Loads a new document titled `name` in `page`.
    func navigate(_ page: WebKitTab, to name: String) async throws {
        let generation = page.state.documentGeneration
        let url = folder.appendingPathComponent("\(name).html")
        try "<!doctype html><title>\(name)</title><p>\(name)</p>".write(to: url, atomically: true, encoding: .utf8)
        page.load(url)
        try await until("\(name) loads") {
            // `&&` takes its right side as a synchronous autoclosure, so the page is read before the test.
            guard page.state.documentGeneration != generation else { return false }
            let title = try? await page.evaluate("document.readyState === 'complete' && document.title", world: .page, gesture: .agent)
            return title == .string(name)
        }
    }
}

/// The shim's renderer call for browser 7: its main frame's pid; every other function does nothing.
nonisolated enum CrashedSubframeShim {
    static let mainPID: Int32 = 500

    static func library() throws -> CEFShimLibrary {
        let rendererPID: @convention(c) (Int32) -> Int32 = { _ in CrashedSubframeShim.mainPID }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_renderer_pid": unsafe unsafeBitCast(rendererPID, to: UnsafeMutableRawPointer.self)
            default: unsafe unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
