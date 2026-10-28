import Testing
@testable import CmuxNextBrowser

/// Chromium starts with Chrome's shared-renderer memory caps from the app's budget
/// (`cmux-shared-renderer-memory-limit`, `cmux-shared-renderer-subframe-memory-limit`), which the fork reads in
/// HasEnoughMemoryForAnotherMainFrame and for a cmux page that joins a live renderer. A bench run may set a lower
/// cap (bench_renderer_sharing --memory-cap-mb) that replaces the budget's.
@Suite struct CEFSharedRendererMemoryCapsTests {
    static let chromeCaps = CEFSharedRendererMemoryCaps(mainFrameBytes: 2 << 30, subframeBytes: 512 << 20)

    private func switches(caps: CEFSharedRendererMemoryCaps?, bundle: String = "com.cmuxterm.app.next",
                          bench: String? = nil) -> [String] {
        CEFSwitches.current(forkAPIVersion: 32, bundleIdentifier: bundle,
                            environment: bench.map { ["CMUX_NEXT_BENCH_CEF_SWITCHES": $0] } ?? [:],
                            sharedRendererMemoryCaps: caps).arguments
    }

    @Test(arguments: [Int32(0), 27, 32])
    func theBudgetsCapsGoToChromiumOnceEach(forkAPIVersion: Int32) {
        let arguments = CEFSwitches.current(forkAPIVersion: forkAPIVersion, bundleIdentifier: "com.cmuxterm.app.next",
                                            environment: [:], sharedRendererMemoryCaps: Self.chromeCaps).arguments
        #expect(arguments.filter { $0 == "cmux-shared-renderer-memory-limit=2147483648" }.count == 1, "\(arguments)")
        #expect(arguments.filter { $0 == "cmux-shared-renderer-subframe-memory-limit=536870912" }.count == 1, "\(arguments)")
    }

    @Test func noCapsPassNoSwitch() {
        let arguments = switches(caps: nil)
        #expect(!arguments.contains { $0.hasPrefix("cmux-shared-renderer-") }, "\(arguments)")
    }

    @Test func aCapOfZeroLeavesChromesValue() {
        let arguments = switches(caps: CEFSharedRendererMemoryCaps(mainFrameBytes: 0, subframeBytes: 512 << 20))
        #expect(!arguments.contains { $0.hasPrefix("cmux-shared-renderer-memory-limit") }, "\(arguments)")
        #expect(arguments.contains("cmux-shared-renderer-subframe-memory-limit=536870912"), "\(arguments)")
    }

    /// The bench grows a page past a small cap: its value is the only one Chromium gets.
    @Test(arguments: ["com.cmuxterm.app.debug.bench-tag", "com.cmuxterm.app.next.dev"])
    func aBenchCapReplacesTheBudgets(bundle: String) {
        let arguments = switches(caps: Self.chromeCaps, bundle: bundle,
                                 bench: "--cmux-shared-renderer-memory-limit=268435456\nhost-resolver-rules=MAP *.test 127.0.0.1")
        #expect(arguments.filter { $0.hasPrefix("cmux-shared-renderer-memory-limit=") } == ["cmux-shared-renderer-memory-limit=268435456"],
                "\(arguments)")
        #expect(arguments.contains("cmux-shared-renderer-subframe-memory-limit=536870912"), "\(arguments)")
    }

    @Test func aReleaseBundleTakesNoBenchCap() {
        let arguments = switches(caps: Self.chromeCaps, bench: "cmux-shared-renderer-memory-limit=1")
        #expect(arguments.filter { $0.hasPrefix("cmux-shared-renderer-memory-limit=") } == ["cmux-shared-renderer-memory-limit=2147483648"],
                "\(arguments)")
    }
}
