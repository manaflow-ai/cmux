@testable import CmuxNextBridge
import Foundation
import Testing

/// NIGHTLY hang 2026-10-29T21:46 (2.7 s): the sidebar row flush sat in `SidebarMapping.abbreviate`, which asked
/// `NSHomeDirectory()` for a bridged NSString on every call and then appended "/" to it, so each call copied the
/// home path through `getBytes` (`_foreignDistance`). A row map calls it per tab (`isIdle`, `folderTab`, `process`,
/// the shortened folder), so a flush of many rows paid that copy thousands of times on the main thread.
/// The home folder is read once per mapping as a native string.
@Suite struct SidebarAbbreviateCostTests {
    static let home = NSHomeDirectory()
    static let paths: [String] = (0..<10_000).map { "\(home)/fun/project-\($0)/src" } + (0..<10_000).map { "/tmp/other-\($0)" }

    @Test func shortensOnlyThisMacsHome() {
        let mapping = SidebarMapping.shared
        #expect(mapping.abbreviate(Self.home) == "~")
        #expect(mapping.abbreviate(Self.home + "/fun/cmux") == "~/fun/cmux")
        #expect(mapping.abbreviate(Self.home + "-other/x") == Self.home + "-other/x")
        #expect(mapping.abbreviate("/tmp/x") == "/tmp/x")
    }

    /// 20,000 abbreviations (a full remap of a large sidebar) cost a fraction of what the pre-fix shape did (`preFix`:
    /// `NSHomeDirectory()` read and "/" appended on every call): before the fix about 40 ms in a debug test build,
    /// after about 5 ms. The two loops run interleaved in this process and each keeps its fastest pass, so a busy
    /// runner slows both alike: a fixed 15 ms budget on the median failed at 17.7 ms on a loaded CI runner
    /// (cmux#36302) while the same Mac measured 4.8 ms quiet at that commit and its parent.
    @Test func twentyThousandAbbreviationsStayCheap() {
        let mapping = SidebarMapping.shared
        var total = 0
        func pass(_ abbreviate: (String) -> String) -> Duration {
            let started = ContinuousClock.now
            for path in Self.paths { total &+= abbreviate(path).utf8.count }
            return ContinuousClock.now - started
        }
        _ = pass(mapping.abbreviate)
        _ = pass(Self.preFix)
        var fast: [Duration] = []
        var slow: [Duration] = []
        for _ in 0..<7 {
            fast.append(pass(mapping.abbreviate))
            slow.append(pass(Self.preFix))
        }
        let fastest = fast.min()!
        let preFixFastest = slow.min()!
        let ratio = preFixFastest / fastest
        print("abbreviate x20000: min \(fastest), p50 \(fast.sorted()[fast.count / 2]); pre-fix min \(preFixFastest); ratio \(ratio), checksum \(total)")
        #expect(ratio >= 3, "abbreviate min \(fastest) against pre-fix min \(preFixFastest) (ratio \(ratio)) for 20,000 paths")
    }

    /// `SidebarMapping.abbreviate` before the fix, the calibration the test measures against.
    private static func preFix(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
