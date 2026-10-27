import CoreGraphics
@testable import CmuxNextBrowser
import Foundation
import Testing

/// Window requests in host mode (task 031 of plans/cmux-next/chrome-parity/p01-process.md): cmux installs
/// no window request handler, pushes the policy the decision reads (`cmux_shim_set_window_request_policy`)
/// when it changes, and applies the decision the Chromium Host reports (WINDOW_REQUEST_RESULT) as it
/// applies its own in process. The host's side of the rule is `CEFShim/tests/window_request_policy_test.cpp`.
@MainActor @Suite(.serialized) struct CEFWindowRequestPolicyTests {
    // MARK: The pushed policy's C rows

    @Test func theRowsHaveTheHeadersLayout() {
        let policy = CEFWindowRequestPolicy(
            windows: [
                .init(anchor: 3, store: "/p/Profile-A", candidate: true, lastShown: true, visible: true),
                .init(anchor: 1 << 20, opener: 3, store: "otr-é", candidate: false, offTheRecord: true),
            ],
            clicks: [.init(browser: 3, gesture: .cmdShift, uptimeMs: 1_234)],
            profileRoot: "/p"
        )
        policy.withRows { windows, windowCount, clicks, clickCount in
            #expect(windowCount == 2 && clickCount == 1)
            func window(_ index: Int, _ offset: Int) -> Int64 {
                windows.load(fromByteOffset: index * CEFWindowRequestPolicy.windowStride + offset, as: Int64.self)
            }
            func store(_ index: Int) -> String {
                let base = index * CEFWindowRequestPolicy.windowStride
                let bytes = windows.load(fromByteOffset: base + 24, as: UnsafeRawPointer?.self)
                let length = windows.load(fromByteOffset: base + 32, as: Int.self)
                return String(decoding: UnsafeRawBufferPointer(start: bytes, count: length), as: UTF8.self)
            }
            #expect(window(0, 0) == 3 && window(0, 8) == 0 && window(0, 16) == 1 | 2 | 4)
            #expect(store(0) == "/p/Profile-A")
            #expect(window(1, 0) == 1 << 20 && window(1, 8) == 3 && window(1, 16) == 8)
            #expect(store(1) == "otr-é", "a store is its UTF-8 bytes, not its characters")
            #expect(clicks.load(fromByteOffset: 0, as: Int64.self) == 3)
            #expect(clicks.load(fromByteOffset: 8, as: Int64.self) == Int64(CEFWindowRequestPolicy.GestureCode.cmdShift.rawValue))
            #expect(clicks.load(fromByteOffset: 16, as: Int64.self) == 1_234)
        }
    }

    @Test func theCodesAreTheHeadersValues() {
        #expect(BrowserLinkGesture.allCases.map { CEFWindowRequestPolicy.GestureCode($0).rawValue } == [0, 1, 2, 3, 4, 5, 6])
        let mapping = BrowserLinkClickMapping(cmdClick: .linkPlacement, cmdShiftClick: .currentTab, shiftClick: .newWindow,
                                              optionClick: .download, middleClick: .foregroundTab)
        #expect(CEFWindowRequestPolicy(mapping: mapping).actionCodes == [3, 0, 4, 5, 2])
        #expect(CEFWindowRequestPolicy().actionCodes == [1, 2, 4, 5, 1], "Chrome's mapping until the App sets one")
        let newTabs: [BrowserNewTabDisposition] = [.foregroundTab, .backgroundTab, .linkPlacement, .popup, .newWindow]
        #expect((0...4).map { CEFWindowRequestResult.NewTab(rawValue: Int32($0))?.disposition } == newTabs)
    }

    /// Only a click that can still decide a request goes to the host (CEFLinkClicks.clickLifetime).
    @Test func onlyFreshClicksArePushed() {
        let context = CEFLinkContext(clicks: [
            9: CEFLinkClickRecord(gesture: .cmd, timestamp: 99.5),
            4: CEFLinkClickRecord(gesture: .middle, timestamp: 100.25),
            7: CEFLinkClickRecord(gesture: .shift, timestamp: 98),
            5: CEFLinkClickRecord(gesture: .option, timestamp: 101),
        ], now: 100.25)
        #expect(CEFWindowRequestPolicy.clicks(of: context) == [
            .init(browser: 4, gesture: .middle, uptimeMs: 100_250),
            .init(browser: 9, gesture: .cmd, uptimeMs: 99_500),
        ])
    }

    // MARK: The host's result

    @Test func anInsertNamesItsAnchorWindowPlacementAndMintedTab() {
        let packed: Int64 = 1 | 3 << 8 | 2 << 16 | 5 << 24 | 1 << 31 | Self.hostMinted << 32
        let result = CEFWindowRequestResult(browser: 7, window: 70, anchor: 3, packed: packed, url: "https://p/",
                                            placement: "10,20,300,200;/p/Profile-A")
        #expect(result?.decision == .insert(anchor: 3, disposition: .popup))
        #expect(result?.window == 70)
        #expect(result?.tab == Int32(Self.hostMinted), "the id the host minted for the tab, from b's high 32 bits")
        #expect(result?.request == CEFWindowRequest(kind: .popup, disposition: .newPopup, sourceBrowser: 7,
                                                    bounds: CGRect(x: 10, y: 20, width: 300, height: 200),
                                                    url: "https://p/", userGesture: true, profilePath: "/p/Profile-A"))
    }

    @Test func everyOutcomeDecodes() {
        func decision(_ outcome: Int64, newTab: Int64 = 0) -> CEFWindowDecision? {
            CEFWindowRequestResult(browser: 7, window: 70, anchor: 0, packed: outcome | newTab << 8, url: "https://n/",
                                   placement: ";/p/Profile-A")?.decision
        }
        #expect(decision(2, newTab: 2) == .openInNewTab(url: "https://n/", disposition: .linkPlacement))
        #expect(decision(3) == .loadInSource(url: "https://n/"))
        #expect(decision(4) == .downloadInSource(url: "https://n/"))
        #expect(decision(5) == .openOffTheRecord(url: "https://n/"))
        #expect(decision(6) == .refuse(.noWindow))
        let refused = CEFWindowRequestResult(browser: 0, window: 70, anchor: 0, packed: 6, url: "", placement: ";")
        #expect(refused?.window == 0 && refused?.tab == 0 && refused?.request.bounds == nil && refused?.request.profilePath == "")
        let oldHost = CEFWindowRequestResult(browser: 7, window: 70, anchor: 3, packed: 1, url: "", placement: ";s")
        #expect(oldHost?.tab == 0 && oldHost?.request.userGesture == false, "a host that mints no id: the placement goes by window")
    }

    /// The host's output is untrusted: what it may not send opens nothing.
    @Test func whatTheHostMayNotSendOpensNothing() {
        func result(anchor: Int64 = 3, packed: Int64 = 1, placement: String = ";s") -> CEFWindowRequestResult? {
            CEFWindowRequestResult(browser: 7, window: 70, anchor: anchor, packed: packed, url: "https://p/", placement: placement)
        }
        #expect(result() != nil)
        #expect(result(anchor: 0) == nil, "an insert with no anchor")
        #expect(result(anchor: Int64(Int32.max) + 1) == nil, "an anchor that is no browser id")
        #expect(result(packed: 7) == nil && result(packed: 0) == nil, "an unknown outcome")
        #expect(result(packed: 1 | 5 << 8) == nil, "an unknown new tab disposition")
        #expect(result(packed: 2 | Self.hostMinted << 32) == nil, "a minted tab on a result that opens no tab")
        #expect(result(packed: 1 | Int64(bitPattern: 0x8000_0000_0000_0000)) == nil, "a minted id that is no browser id")
        #expect(result(placement: "/p/Profile-A") == nil, "a placement with no store separator")
        #expect(CEFShimEvent(kind: 61, browser: 7, request: 70, a: 0, b: 1, s1: "", s2: ";s") == .unknown(kind: 61))
        let decoded = CEFShimEvent(kind: 61, browser: 7, request: 70, a: 3, b: 1, s1: "https://p/", s2: ";s")
        #expect(decoded == result().map(CEFShimEvent.windowRequestResult))
    }

    // MARK: The runtime

    @Test func hostModeInstallsNoHandlerAndPushesThePolicyOnlyWhenItChanges() throws {
        PolicySpy.reset()
        let root = Self.root()
        let runtime = CEFRuntime(shim: try PolicySpy.library(), storage: CEFProfileStorage(root: root))
        var turns: [@MainActor @Sendable () -> Void] = []
        runtime.windowRequests.endOfTurn = { turns.append($0) }
        runtime.windowRequests.install(on: try #require(runtime.shim), hostMode: true)
        #expect(PolicySpy.handlerInstalled == false, "the host never asks cmux inside its navigation")
        #expect(PolicySpy.pushes.isEmpty, "the first push waits for the end of the turn, after initialize")
        #expect(turns.count == 1)
        turns.removeAll()
        runtime.windowRequests.policyMayHaveChanged()
        #expect(turns.isEmpty, "one push per turn")

        runtime.windowRequests.pushPolicy()
        #expect(PolicySpy.pushes == [.init(windows: 0, clicks: 0, root: CEFRuntime.normalizedPath(root.path),
                                           actions: [1, 2, 4, 5, 1])])
        runtime.windowRequests.pushPolicy()
        #expect(PolicySpy.pushes.count == 1, "an unchanged policy is not pushed again")
        runtime.windowRequests.linkClicks.mapping = BrowserLinkClickMapping(cmdClick: .linkPlacement)
        #expect(PolicySpy.pushes.last?.actions == [3, 2, 4, 5, 1], "a mapping change goes to the host at once")
    }

    @Test func inProcessInstallsTheHandlerAndPushesNothing() throws {
        PolicySpy.reset()
        let runtime = CEFRuntime(shim: try PolicySpy.library(), storage: CEFProfileStorage(root: Self.root()))
        var turns = 0
        runtime.windowRequests.endOfTurn = { _ in turns += 1 }
        runtime.windowRequests.install(on: try #require(runtime.shim), hostMode: false)
        #expect(PolicySpy.handlerInstalled == true)
        runtime.windowRequests.policyMayHaveChanged()
        runtime.windowRequests.linkClicks.mapping = BrowserLinkClickMapping(cmdClick: .linkPlacement)
        #expect(turns == 0 && PolicySpy.pushes.isEmpty)
    }

    /// The host's insert records the placement of the tab it opens under the id the host minted for it,
    /// before its AFTER_CREATED, which names the tab by that id: the tab takes it whatever window it
    /// reports. A host that mints no id leaves the placement to the window, as cmux's own insert in process.
    @Test func aHostInsertRecordsThePlacementOfTheTabItOpens() throws {
        let runtime = CEFRuntime(shim: try PolicySpy.library(), storage: CEFProfileStorage(root: Self.root()))
        let minted = Int32(Self.hostMinted)
        let insert = try #require(CEFWindowRequestResult(browser: 7, window: 70, anchor: 3,
                                                          packed: 1 | 1 << 8 | Self.hostMinted << 32, url: "https://p/",
                                                          placement: "1,2,3,4;/p/Profile-A"))
        runtime.handle(.windowRequestResult(insert))
        #expect(runtime.windowRequests.log.count == 1)
        #expect(runtime.windowRequests.log.recent.last?.tab == minted, "debug.cef names the minted tab")
        #expect(runtime.takePlacement(browser: 9, window: 70, fallback: .foregroundTab).bounds == nil,
                "another tab of the window does not take the minted tab's placement")
        let placement = runtime.takePlacement(browser: minted, window: 0, fallback: .foregroundTab)
        #expect(placement.disposition == .backgroundTab && placement.bounds == CGRect(x: 1, y: 2, width: 3, height: 4))
        #expect(runtime.takePlacement(browser: minted, window: 0, fallback: .foregroundTab).bounds == nil, "taken once")

        let byWindow = try #require(CEFWindowRequestResult(browser: 7, window: 70, anchor: 3, packed: 1 | 1 << 8, url: "https://p/",
                                                            placement: "5,6,7,8;/p/Profile-A"))
        runtime.handle(.windowRequestResult(byWindow))
        #expect(runtime.takePlacement(browser: 11, window: 70, fallback: .foregroundTab).bounds == CGRect(x: 5, y: 6, width: 7, height: 8))

        let refused = try #require(CEFWindowRequestResult(browser: 7, window: 70, anchor: 0, packed: 6, url: "", placement: ";otr"))
        runtime.handle(.windowRequestResult(refused))
        #expect(runtime.windowRequests.log.refused == 1)
        #expect(runtime.takePlacement(browser: 12, window: 70, fallback: .foregroundTab).bounds == nil, "a refusal places nothing")
    }

    /// A placement whose tab Chromium never created stays only until newer ones push it out.
    @Test func placementsByMintedTabAreBounded() {
        var queue = CEFPlacementQueue()
        let first = Int32(Self.hostMinted)
        for offset in 0...Int32(CEFPlacementQueue.maxTabPlacements) {
            queue.record(tab: first + offset, CEFPlacement(disposition: .popup, bounds: nil))
        }
        #expect(queue.take(tab: first) == nil, "the oldest left")
        #expect(queue.take(tab: first + 1)?.disposition == .popup)
        #expect(queue.take(tab: first + Int32(CEFPlacementQueue.maxTabPlacements))?.disposition == .popup)
    }

    /// chromium_host_mint.h's kFirstHostBrowserID: the first id the host mints for a window request's tab.
    private static let hostMinted: Int64 = 1 << 30

    private static func root() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "cef-window-policy-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}

/// A shim that records the window request handler and every pushed policy (a C function captures nothing).
private nonisolated enum PolicySpy {
    struct Push: Equatable {
        var windows: Int32
        var clicks: Int32
        var root: String
        var actions: [Int32]
    }

    nonisolated(unsafe) static var handlerInstalled: Bool?
    nonisolated(unsafe) static var pushes: [Push] = []

    static func reset() {
        handlerInstalled = nil
        pushes = []
    }

    static func library() throws -> CEFShimLibrary {
        let setHandler: @convention(c) (CEFShimLibrary.WindowRequestFn?) -> Void = { PolicySpy.handlerInstalled = $0 != nil }
        let setPolicy: @convention(c) (UnsafeRawPointer?, Int32, UnsafeRawPointer?, Int32, UnsafePointer<CChar>?,
                                       Int32, Int32, Int32, Int32, Int32) -> Void = { _, windows, _, clicks, root, a, b, c, d, e in
            PolicySpy.pushes.append(Push(windows: windows, clicks: clicks, root: root.map { String(cString: $0) } ?? "",
                                         actions: [a, b, c, d, e]))
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_set_window_request_handler": unsafeBitCast(setHandler, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_set_window_request_policy": unsafeBitCast(setPolicy, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
