@testable import CmuxVNCWebRTC
import Foundation
import Testing

/// ``ScreenRules`` from libcmux_rd_screen.dylib (cmux-tui/crates/cmux-rd-screen-ffi, whose own
/// tests check the C ABI against cmux-rd-screen's answers).
struct ScreenRulesLibraryTests {
    /// A path with no library gives no rules, never a crash.
    @Test func noLibraryNoRules() {
        #expect(ScreenRules.library(at: URL(fileURLWithPath: "/nonexistent/\(ScreenRules.libraryName)")) == nil)
    }

    /// With a built library (CMUX_RD_SCREEN_DYLIB, e.g. cmux-tui's
    /// target/release/libcmux_rd_screen_ffi.dylib) the host's demand is the rules' answer.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_RD_SCREEN_DYLIB"] != nil))
    func theLibraryAnswersTheDemandOps() throws {
        let path = try #require(ProcessInfo.processInfo.environment["CMUX_RD_SCREEN_DYLIB"])
        let rules = try #require(ScreenRules.library(at: URL(fileURLWithPath: path)))
        #expect(rules.installed)
        #expect(ScreenRules.bundled.installed)
        var demand = ViewerDemand(rules: rules)
        _ = demand.report(longEdge: 1179, displayLongEdge: 3456, pinch: false, now: 0)
        _ = demand.report(longEdge: 1179, displayLongEdge: 3456, pinch: false, now: 6)
        #expect(demand.cap == 1280, "a viewer showing 1179 points of a 3456-point display caps the capture at 1280")
    }
}
