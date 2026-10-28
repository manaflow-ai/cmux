import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// Task 019 of plans/cmux-next/chrome-parity/p01-process.md: in host mode, with a host that maps
/// the ids cmux mints, cmux mints the ids of the browsers it creates (`tab_add` and
/// `tab_duplicate` return the minted id at once, and the browser's AFTER_CREATED comes in a later
/// event batch), so no Swift path waits for an id. A tab shown in a pane whose window is live has
/// its browser in the turn that shows it, a new pane asks for its window in that turn, and the
/// later AFTER_CREATED of a minted id completes that tab instead of adopting an orphan. A host
/// that refuses a minted browser sends CREATE_FAILED: the tab stays with the failure page, as in
/// process after the shim's 0.
@MainActor @Suite(.serialized) struct ChromiumHostMintTests {
    /// Host mode: the tab joins the live window in the turn that shows it, as Chromium's active
    /// tab, with the id cmux minted; nothing waits for the frame to commit.
    @Test func aTabShownInALiveWindowHasItsMintedBrowserInTheSameTurn() throws {
        let (runtime, root) = try Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, _, container) = try Self.liveHost(runtime)

        let link = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(link)
        host.present(link, in: container)

        let minted = MintSpyShim.firstMinted + 1
        #expect(link.browserID == minted, "the minted id, in the turn that showed the tab")
        #expect(MintSpyShim.added.map(\.anchor) == [MintSpyShim.firstMinted], "joined the pane's window")
        #expect(MintSpyShim.added.map(\.activate) == [1], "as Chromium's active tab")
        #expect(MintSpyShim.activated.isEmpty, "one activation source: tab_add's")
        #expect(host.deferredCreations.isEmpty, "nothing waits for the frame to commit")
        #expect(host.lastActivated == minted)
        // Host mode: the pane's ChromiumHostPageView shows the page; no fork layer hosting (task 023).
        #expect(!host.hostView.layerHosting.isForkBacked)
        #expect(host.hostedPageView != nil)

        // The host's AFTER_CREATED for the minted id, a batch later: the same tab, no orphan.
        runtime.handle(.afterCreated(browser: minted, request: 0, window: 1))
        #expect(runtime.tabsByBrowser[minted] === link)
        #expect(host.tabs.count == 2)
    }

    /// In process `tab_add` builds the tab in Chromium on the main thread, so the shown tab still
    /// joins after the frame committed (PL-cef-tab).
    @Test func inProcessATabShownInALiveWindowJoinsAfterTheFrame() throws {
        let (runtime, root) = try Self.runtime(hostMode: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, _, container) = try Self.liveHost(runtime)

        let link = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(link)
        host.present(link, in: container)
        #expect(link.browserID == nil)
        #expect(MintSpyShim.added.isEmpty, "the turn that shows the tab joins no window")
        host.createDeferred()
        #expect(link.browserID == MintSpyShim.firstMinted + 1)
        #expect(host.tabs.count == 2)
    }

    /// Host mode: a duplicate returns its tab at once, under the minted id, announced by its source
    /// as a background tab; the copy's later AFTER_CREATED adopts nothing.
    @Test func aDuplicateIsItsMintedTabAtOnce() throws {
        let (runtime, root) = try Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, first, _) = try Self.liveHost(runtime)
        let intents = Intents()
        first.delegate = intents

        let copy = try #require(host.duplicate(first))

        let minted = MintSpyShim.firstMinted + 1
        #expect(MintSpyShim.duplicated.map(\.source) == [MintSpyShim.firstMinted])
        #expect(copy.browserID == minted)
        #expect(runtime.tabsByBrowser[minted] === copy)
        #expect(host.tabs.contains { $0 === copy })
        #expect(intents.adopted.count == 1)
        #expect(intents.adopted.first?.tab === copy)
        #expect(intents.adopted.first?.disposition == .backgroundTab)

        runtime.handle(.afterCreated(browser: minted, request: 0, window: 1))
        #expect(runtime.tabsByBrowser[minted] === copy)
        #expect(host.tabs.count == 2, "no orphan adopted for the minted id")
        #expect(intents.adopted.count == 1)
    }

    /// In process the copy's OnAfterCreated runs inside `tab_duplicate`: the same one tab.
    @Test func inProcessADuplicateIsCompletedInsideTheCall() throws {
        let (runtime, root) = try Self.runtime(hostMode: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, first, _) = try Self.liveHost(runtime)
        let intents = Intents()
        first.delegate = intents

        let copy = try #require(host.duplicate(first))

        #expect(copy.browserID == MintSpyShim.firstMinted + 1)
        #expect(host.tabs.count == 2)
        #expect(intents.adopted.count == 1)
        #expect(intents.adopted.first?.tab === copy)
        #expect(runtime.tabBeingAdded == nil)
    }

    /// A duplicate the fork refuses makes no tab.
    @Test func aRefusedDuplicateMakesNoTab() throws {
        let (runtime, root) = try Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, first, _) = try Self.liveHost(runtime)
        let intents = Intents()
        first.delegate = intents
        MintSpyShim.refusesDuplicate = true

        #expect(host.duplicate(first) == nil)
        #expect(host.tabs.count == 1)
        #expect(intents.adopted.isEmpty)
        #expect(runtime.tabBeingAdded == nil)
    }

    /// Host mode: a new pane's tab asks for its window in the turn that shows it (`create_window`
    /// is a post, and the host makes the profile's directory); its browser comes with AFTER_CREATED.
    @Test func aNewPanesTabAsksForItsWindowInTheKeysTurn() throws {
        let (runtime, root) = try Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        host.endOfTurn = { $0() }
        let first = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(first)
        host.present(first, in: NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)))

        #expect(host.deferredCreations.isEmpty, "nothing waits for the frame to commit")
        #expect(runtime.pendingWindows.count == 1, "the window is asked for in the key's turn")
        #expect(host.isCreatingWindow)
        #expect(first.isCreationPending)
        #expect(!FileManager.default.fileExists(atPath: runtime.contextKey(for: host.key)),
                "the host makes the profile's directory, not cmux's main thread")
    }

    /// A host that does not map minted ids yet (its HELLO does not list them): the in-process
    /// order, the browser after the frame, and no duplicate whose id would name nothing.
    @Test func aHostThatDoesNotMapMintedIDsKeepsTheFrameWait() throws {
        let (runtime, root) = try Self.runtime(hostMode: true, mapsIDs: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, first, container) = try Self.liveHost(runtime)

        let link = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(link)
        host.present(link, in: container)
        #expect(link.browserID == nil)
        #expect(host.deferredCreations.count == 1)
        #expect(host.duplicate(first) == nil)
        #expect(MintSpyShim.duplicated.isEmpty)
    }

    /// Host mode: `tab_add` returned the minted id, then the host refused it (the anchor closed in
    /// the host first). The tab stays open with the failure page and no browser; nothing closes it.
    @Test func aRefusedTabAddKeepsTheTabWithTheFailurePage() throws {
        let (runtime, root) = try Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, _, container) = try Self.liveHost(runtime)
        let link = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(link)
        host.present(link, in: container)
        let minted = MintSpyShim.firstMinted + 1
        #expect(link.browserID == minted)

        runtime.handle(.createFailed(browser: minted, request: 0))

        #expect(!link.isClosed, "a refused create is no close")
        #expect(host.tabs.contains { $0 === link })
        #expect(link.browserID == nil)
        #expect(runtime.tabsByBrowser[minted] == nil)
        #expect(!link.isCreationPending)
        #expect(Self.showsFailure(link))
    }

    /// Host mode: a duplicate the host refuses after its id was returned stays, with the failure page.
    @Test func aRefusedDuplicateKeepsItsCopyWithTheFailurePage() throws {
        let (runtime, root) = try Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, first, _) = try Self.liveHost(runtime)
        let copy = try #require(host.duplicate(first))
        let minted = try #require(copy.browserID)

        runtime.handle(.createFailed(browser: minted, request: 0))

        #expect(!copy.isClosed)
        #expect(host.tabs.contains { $0 === copy })
        #expect(copy.browserID == nil)
        #expect(Self.showsFailure(copy))
        #expect(first.browserID == MintSpyShim.firstMinted, "the source keeps its browser")
    }

    /// Host mode: `create_window` returned 1 when sent, then the host refused it. The pane stops
    /// waiting for that window, and its tab and the tab waiting to join it show the failure.
    @Test func aRefusedCreateWindowFailsTheTabsWaitingForIt() throws {
        let (runtime, root) = try Self.runtime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        host.endOfTurn = { $0() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let first = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        let second = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(first)
        host.add(second)
        host.present(first, in: container)
        host.present(second, in: container)
        let request = try #require(runtime.pendingWindows.keys.first)
        #expect(second.isCreationPending, "waits to join the window being built")

        runtime.handle(.createFailed(browser: MintSpyShim.firstMinted, request: request))

        #expect(runtime.pendingWindows.isEmpty)
        #expect(!host.isCreatingWindow && !host.isLive)
        for tab in [first, second] {
            #expect(!tab.isClosed)
            #expect(!tab.isCreationPending)
            #expect(tab.browserID == nil)
            #expect(Self.showsFailure(tab))
        }
    }

    /// The host's CREATE_FAILED (kind 51, `cmux_host::mint::kEventCreateFailed`) decodes with the
    /// minted id and `create_window`'s request.
    @Test func createFailedDecodesWithTheMintedIDAndRequest() {
        let event = CEFShimEvent(kind: 51, browser: MintSpyShim.firstMinted, request: 7, a: 0, b: 0, s1: "", s2: "")
        #expect(event == .createFailed(browser: MintSpyShim.firstMinted, request: 7))
        #expect(event.browserID == MintSpyShim.firstMinted)
    }

    // MARK: Fixtures

    private static func showsFailure(_ tab: CEFTab) -> Bool {
        if case .failed = tab.state.phase { return true }
        return false
    }

    /// A runtime that outlives the test (a shown tab schedules work that reads its runtime through
    /// an unowned reference after the test returned); in host mode when `hostMode`, with a host
    /// that maps minted ids unless `mapsIDs` is false.
    private static func runtime(hostMode: Bool, mapsIDs: Bool = true) throws -> (CEFRuntime, URL) {
        MintSpyShim.reset(hostMode: hostMode)
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-mint-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(shim: try MintSpyShim.library(), storage: CEFProfileStorage(root: root))
        if hostMode {
            runtime.hostStart = CEFHostStart(supervisor: NoHost())
            runtime.hostStart?.mapsClientIDs = mapsIDs
        }
        _ = Unmanaged.passRetained(runtime)
        MintSpyShim.runtime = runtime
        return (runtime, root)
    }

    /// A pane showing a Chromium page in its live window, whose browser is the first minted id.
    private static func liveHost(_ runtime: CEFRuntime) throws -> (CEFPaneHost, CEFTab, NSView) {
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        host.endOfTurn = { $0() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let first = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(first)
        host.present(first, in: container)
        #expect(first.browserID == nil, "the window's browser comes with its AFTER_CREATED")
        if !host.createsBrowsersAtOnce { host.createDeferred() }
        let request = try #require(runtime.pendingWindows.keys.first)
        runtime.handle(.afterCreated(browser: MintSpyShim.firstMinted, request: request, window: 1))
        #expect(host.isLive)
        #expect(first.browserID == MintSpyShim.firstMinted)
        return (host, first, container)
    }
}

/// The adopted tabs a source tab announced.
@MainActor private final class Intents: BrowserTabDelegate {
    private(set) var adopted: [(tab: CEFTab?, disposition: BrowserNewTabDisposition)] = []

    func browserTab(_ tab: any BrowserTab, didRequest intent: BrowserTabIntent) {
        guard case .adoptTab(let adopted, let disposition) = intent else { return }
        self.adopted.append((adopted as? CEFTab, disposition))
    }
}

/// Never attaches: these tests drive the runtime's panes against the spy shim, never start it.
@MainActor private final class NoHost: ChromiumHostSupervising {
    func attachment() async throws(ChromiumHostAttachError) -> ChromiumHostAttachment {
        throw .cannotStart("not started in this test")
    }

    func observeHostEnds(_ ended: @escaping @MainActor () -> Void) {}
}

/// Stand-in shim functions. `create_window` reports the browser started. `tab_add` and
/// `tab_duplicate` return the next id from the minted range (1 << 20, the remote shim's); in
/// process they run the new browser's OnAfterCreated before they return, as the real shim does,
/// in host mode they do not (it comes in a later batch). `tab_activate` records the browser;
/// `fork_api_version` reports 27 (duplicates and layer hosting); every other function does
/// nothing and returns 0.
private nonisolated enum MintSpyShim {
    static let firstMinted: Int32 = 1 << 20
    nonisolated(unsafe) static var hostMode = false
    nonisolated(unsafe) static var next: Int32 = firstMinted + 1
    nonisolated(unsafe) static var refusesDuplicate = false
    nonisolated(unsafe) static var added: [(anchor: Int32, activate: Int32)] = []
    nonisolated(unsafe) static var duplicated: [(source: Int32, anchor: Int32)] = []
    nonisolated(unsafe) static var activated: [Int32] = []
    nonisolated(unsafe) static weak var runtime: CEFRuntime?

    static func reset(hostMode: Bool) {
        self.hostMode = hostMode
        next = firstMinted + 1
        refusesDuplicate = false
        added = []
        duplicated = []
        activated = []
        runtime = nil
    }

    /// The next minted id; in process, its OnAfterCreated inside the call.
    static func mint() -> Int32 {
        let browser = next
        next += 1
        if !hostMode {
            MainActor.assumeIsolated {
                MintSpyShim.runtime?.handle(.afterCreated(browser: browser, request: 0, window: 1))
            }
        }
        return browser
    }

    static func library() throws -> CEFShimLibrary {
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let tabAdd: @convention(c) (Int32, UnsafePointer<CChar>?, Int32, Int32) -> Int32 = { anchor, _, _, activate in
            MintSpyShim.added.append((anchor, activate))
            return MintSpyShim.mint()
        }
        let tabDuplicate: @convention(c) (Int32, Int32, Int32) -> Int32 = { source, anchor, _ in
            MintSpyShim.duplicated.append((source, anchor))
            return MintSpyShim.refusesDuplicate ? 0 : MintSpyShim.mint()
        }
        let tabActivate: @convention(c) (Int32) -> Int32 = { browser in
            MintSpyShim.activated.append(browser)
            return 1
        }
        let forkAPIVersion: @convention(c) () -> Int32 = { 27 }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_tab_add": unsafeBitCast(tabAdd, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_tab_duplicate": unsafeBitCast(tabDuplicate, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_tab_activate": unsafeBitCast(tabActivate, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_fork_api_version": unsafeBitCast(forkAPIVersion, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
