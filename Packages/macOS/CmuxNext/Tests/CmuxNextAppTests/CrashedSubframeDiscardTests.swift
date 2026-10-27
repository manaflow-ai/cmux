import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextSettings
import Foundation
import Testing

/// p07-memory-106, feature `memoryDiscardCrashedSubframes`: a hidden page whose out-of-process frame
/// crashed is discarded with reason external, as Chrome's DiscardPageWithCrashedSubframePolicy does
/// (chrome/browser/performance_manager/policies/discard_page_with_crashed_subframe_policy.cc), so it
/// reloads whole when shown and its renderers' memory goes; a shown page keeps its sad frame. CEF tells a
/// browser only of its main frame's renderer, so the tab learns of a subframe's from the child monitor's
/// renderer end (its `--renderer-client-id`) against the renderers of its frames. Against a spy shim for
/// the Chromium half and real WebKit pages for the hibernation half.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct CrashedSubframeDiscardTests {
    // MARK: The Chromium tab hears its subframe's crash

    @Test func aCrashedOutOfProcessFrameReportsItsPage() throws {
        let rig = try ChromiumRig()
        rig.runtime.childExited(Self.renderer(pid: 900, client: 9, status: SIGSEGV))
        #expect(rig.crashes == 1, "the page did not hear its out-of-process frame crash")
    }

    @Test func theMainFramesRendererEndIsNoSubframeCrash() throws {
        let rig = try ChromiumRig()
        rig.runtime.childExited(Self.renderer(pid: ChromiumRig.mainPID, client: 3, status: SIGSEGV))
        #expect(rig.crashes == 0, "the main frame's crash (the sad tab) counted as a subframe's")
    }

    @Test func aRendererWithNoFrameOfThePageIsNotItsCrash() throws {
        let rig = try ChromiumRig()
        rig.runtime.childExited(Self.renderer(pid: 901, client: 12, status: SIGSEGV))
        #expect(rig.crashes == 0, "another page's renderer crash reached this page")
    }

    @Test func aNormalRendererExitIsNoCrash() throws {
        let rig = try ChromiumRig()
        rig.runtime.childExited(Self.renderer(pid: 900, client: 9, status: 0))
        #expect(rig.crashes == 0, "a renderer Chromium let go counted as a crash")
    }

    /// Chromium drops a dead renderer's frames when it hears of the death, which can come before the
    /// child monitor's exit event: the frames the tab read before (here when its hook was set) still count.
    @Test func aFrameChromiumForgotBeforeTheExitEventStillCounts() throws {
        let rig = try ChromiumRig()
        SubframeShim.clients = [3]
        rig.runtime.childExited(Self.renderer(pid: 900, client: 9, status: SIGSEGV))
        #expect(rig.crashes == 1, "a frame Chromium had already forgotten was missed")
    }

    @Test func theHelperIdentityCarriesTheRendererClientID() {
        let identity = CEFHelperIdentity.parse(["Helper (Renderer)", "--type=renderer", "--renderer-client-id=42"])
        #expect(identity?.rendererClientID == 42)
        #expect(ChromiumHelperProcess.classify(["--type=renderer", "--renderer-client-id=42"]) == .renderer(clientID: 42))
        #expect(CEFHelperIdentity.parse(["--type=gpu-process"])?.rendererClientID == nil)
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
        let page = try await rig.page("shown", body: "<p>shown</p>")
        let key = page.id.rawValue
        rig.keys.append(key)
        rig.services.cache.install(page, for: key)
        rig.services.cache.present(key, by: rig.pane, presence: .visible)
        try #require(rig.services.cache.phase(of: key) == .mountedVisible)

        rig.hibernation.subframeDidCrash(key)
        #expect(!rig.hibernation.probing.contains(key), "a shown tab started a discard")
        #expect(!rig.isHibernated(key))
        #expect(rig.services.cache.browsers[key]?.tab === page, "the shown tab's page was replaced")
    }

    @Test func withTheFeatureOffAHiddenTabKeepsItsCrashedFrame() async throws {
        let rig = try Self.hibernationRig(feature: false)
        defer { rig.close() }
        let key = try await rig.hide(rig.page("off", body: "<p>off</p>"))
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

    /// A renderer's end as the child monitor reports it.
    static func renderer(pid: Int32, client: Int32, status: Int32) -> CEFChildProcessMonitor.Exit {
        CEFChildProcessMonitor.Exit(pid: pid, processType: "renderer", subType: nil, isExtension: false, status: status,
                                    rendererClientID: client)
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

    /// A ready in-process runtime over ``SubframeShim`` with one tab, browser 7, whose main frame is in
    /// renderer 3 (pid ``mainPID``) and an out-of-process frame in renderer 9; `follows` sets its hook.
    @MainActor final class ChromiumRig {
        static let mainPID: Int32 = 500
        let runtime: CEFRuntime
        let tab: CEFTab
        private(set) var crashes = 0

        init(follows: Bool = true) throws {
            SubframeShim.clients = [3, 9]
            SubframeShim.mainPID = Self.mainPID
            let root = FileManager.default.temporaryDirectory.appending(path: "cef-subframe-crash-\(UUID().uuidString)", directoryHint: .isDirectory)
            runtime = CEFRuntime(shim: try SubframeShim.library(), storage: CEFProfileStorage(root: root))
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

/// The shim's renderer calls for browser 7: its frames' renderer client ids and its main frame's pid;
/// every other function does nothing.
private nonisolated enum SubframeShim {
    nonisolated(unsafe) static var clients: [Int32] = []
    nonisolated(unsafe) static var mainPID: Int32 = 0

    static func library() throws -> CEFShimLibrary {
        let clientIDs: @convention(c) (Int32, UnsafeMutablePointer<Int32>?, Int32) -> Int32 = { _, out, capacity in
            guard let out else { return 0 }
            let ids = SubframeShim.clients.prefix(Int(max(capacity, 0)))
            // SAFETY: the caller's buffer holds `capacity` ids; at most that many are written.
            for (at, id) in ids.enumerated() { unsafe out[at] = id }
            return Int32(ids.count)
        }
        let rendererPID: @convention(c) (Int32) -> Int32 = { _ in SubframeShim.mainPID }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_renderer_client_ids": unsafe unsafeBitCast(clientIDs, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_renderer_pid": unsafe unsafeBitCast(rendererPID, to: UnsafeMutableRawPointer.self)
            default: unsafe unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
