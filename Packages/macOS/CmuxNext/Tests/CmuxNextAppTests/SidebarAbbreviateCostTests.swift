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

    /// 20,000 abbreviations (a full remap of a large sidebar) stay well under one frame budget per 1,000:
    /// before the fix, about 40 ms in a debug test build; after, about 5 ms.
    @Test func twentyThousandAbbreviationsStayCheap() {
        let mapping = SidebarMapping.shared
        var samples: [Duration] = []
        var total = 0
        for _ in 0..<7 {
            let started = ContinuousClock.now
            for path in Self.paths { total &+= mapping.abbreviate(path).utf8.count }
            samples.append(ContinuousClock.now - started)
        }
        samples.sort()
        let median = samples[samples.count / 2]
        print("abbreviate x20000: p50 \(median), max \(samples.last!), checksum \(total)")
        #expect(median < .milliseconds(15), "median \(median) for 20,000 abbreviations")
    }
}
