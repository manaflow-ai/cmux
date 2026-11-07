import Foundation
import Testing
@testable import CmuxFoundation

/// Covers ``CmuxGrowingWindowPager``: a filtered Vault page grows its reads
/// until enough rows pass the filter, without letting hidden rows consume the
/// requested window and without reading the whole source for a small page.
@Suite("Growing window pager")
struct CmuxGrowingWindowPagerTests {
    // MARK: Snapshot windows

    @Test("A filtered snapshot page parses later windows only until it is full")
    func snapshotPageGrowsUntilFull() async {
        let hidden = Set(0..<40)
        let windows = Recorder<Range<Int>>()

        let page = await CmuxGrowingWindowPager(cap: 1500).snapshotPage(
            candidateCount: 200,
            offset: 5,
            limit: 10,
            grows: true,
            parse: { range in
                windows.append(range)
                return Array(range)
            },
            isIncluded: { !hidden.contains($0) }
        )

        #expect(page == Array(45..<55))
        #expect(windows.values == [0..<30, 30..<60])
    }

    @Test("A filtered snapshot page keeps parsing past windows the loader mostly drops")
    func snapshotPageGrowsPastDroppedWindows() async {
        // Like Claude's loader: a window's sessions outside the folder or the
        // search are dropped, so a short window is not the end of the snapshot.
        let windows = Recorder<Range<Int>>()

        let page = await CmuxGrowingWindowPager(cap: 1500).snapshotPage(
            candidateCount: 400,
            offset: 0,
            limit: 20,
            grows: true,
            parse: { range in
                windows.append(range)
                return range.filter { $0 % 10 == 0 }
            },
            isIncluded: { _ in true }
        )

        #expect(page.count == 20)
        #expect(windows.values == [0..<40, 40..<80, 80..<160, 160..<320])
    }

    @Test("A snapshot page stops at the snapshot end or the cap, and an unfiltered page parses one window")
    func snapshotPageStopsAtEndOrCap() async {
        let exhausted = Recorder<Range<Int>>()
        let capped = Recorder<Range<Int>>()
        let unfiltered = Recorder<Range<Int>>()
        let odd = Recorder<Range<Int>>()

        let short = await CmuxGrowingWindowPager(cap: 1500).snapshotPage(
            candidateCount: 50, offset: 0, limit: 30, grows: true,
            parse: { exhausted.append($0); return Array($0) },
            isIncluded: { $0 != 0 }
        )
        _ = await CmuxGrowingWindowPager(cap: 120).snapshotPage(
            candidateCount: 10_000, offset: 0, limit: 100, grows: true,
            parse: { capped.append($0); return [Int]() },
            isIncluded: { _ in true }
        )
        _ = await CmuxGrowingWindowPager(cap: 1500).snapshotPage(
            candidateCount: 10_000, offset: 0, limit: 30, grows: false,
            parse: { unfiltered.append($0); return [Int]() },
            isIncluded: { _ in true }
        )
        _ = await CmuxGrowingWindowPager(cap: 1500).snapshotPage(
            candidateCount: 101, offset: 0, limit: 50, grows: false,
            parse: { odd.append($0); return [Int]() },
            isIncluded: { _ in true }
        )

        #expect(short.count == 30)
        #expect(exhausted.values == [0..<50])
        #expect(capped.values == [0..<120])
        #expect(unfiltered.values == [0..<60])
        #expect(odd.values == [0..<100])
    }

    // MARK: Prefix reads

    @Test("A filtered prefix page reads twice the page when that fills it")
    func prefixPageReadsTwiceThePage() async {
        let reads = Recorder<Int>()

        let page = await CmuxGrowingWindowPager(cap: 1500).prefixPage(
            offset: 0,
            limit: 30,
            startsSmall: true,
            read: { limit in
                reads.append(limit)
                return Array(0..<min(limit, 10_000))
            },
            isIncluded: { $0 % 2 == 0 }
        )

        #expect(page == Array(stride(from: 0, to: 60, by: 2)))
        #expect(reads.values == [60])
    }

    @Test("A filtered prefix page reads up to the cap once twice the page is not enough")
    func prefixPageReadsTheCapWhenShort() async {
        // Each read reruns the loader (database copy, directory listing), so
        // a short page takes one more read at the cap rather than doubling.
        let reads = Recorder<Int>()

        let page = await CmuxGrowingWindowPager(cap: 1500).prefixPage(
            offset: 10,
            limit: 10,
            startsSmall: true,
            read: { limit in
                reads.append(limit)
                return Array(0..<min(limit, 10_000))
            },
            isIncluded: { $0 >= 100 }
        )

        #expect(page == Array(110..<120))
        #expect(reads.values == [40, 1500])
    }

    @Test("A prefix page stops at the cap, or when the first read fills it")
    func prefixPageStopsAtCapOrWhenFull() async {
        let capped = Recorder<Int>()
        let exhausted = Recorder<Int>()

        let none = await CmuxGrowingWindowPager(cap: 100).prefixPage(
            offset: 0, limit: 30, startsSmall: true,
            read: { capped.append($0); return Array(0..<$0) },
            isIncluded: { _ in false }
        )
        let rest = await CmuxGrowingWindowPager(cap: 1500).prefixPage(
            offset: 0, limit: 30, startsSmall: true,
            read: { exhausted.append($0); return Array(0..<min($0, 50)) },
            isIncluded: { $0 != 0 }
        )

        #expect(none.isEmpty)
        #expect(capped.values == [60, 100])
        #expect(rest == Array(1..<31))
        #expect(exhausted.values == [60])
    }

    @Test("A short first read is confirmed by a read at the cap before the page ends")
    func prefixPageConfirmsShortRead() async {
        // Like Antigravity's history: a request of exactly the preview size
        // reads one page, so its short result is not the end of the source.
        let reads = Recorder<Int>()

        let page = await CmuxGrowingWindowPager(cap: 1500).prefixPage(
            offset: 0,
            limit: 15,
            startsSmall: true,
            read: { limit in
                reads.append(limit)
                return Array(0..<(limit == 30 ? 5 : min(limit, 200)))
            },
            isIncluded: { _ in true }
        )

        #expect(page == Array(0..<15))
        #expect(reads.values == [30, 1500])
    }

    @Test("A source shorter than the page ends after the read at the cap")
    func prefixPageEndsAfterTheCapRead() async {
        let reads = Recorder<Int>()

        let page = await CmuxGrowingWindowPager(cap: 1500).prefixPage(
            offset: 0,
            limit: 30,
            startsSmall: true,
            read: { limit in
                reads.append(limit)
                return Array(0..<min(limit, 50))
            },
            isIncluded: { $0 % 5 == 0 }
        )

        #expect(page == Array(stride(from: 0, to: 50, by: 5)))
        #expect(reads.values == [60, 1500])
    }

    @Test("A page that does not start small reads once, at the cap")
    func prefixPageWithoutSmallStartReadsTheCapOnce() async {
        // A search already scans up to the cap in every loader, so a smaller
        // first read would only repeat that work.
        let reads = Recorder<Int>()

        let page = await CmuxGrowingWindowPager(cap: 1500).prefixPage(
            offset: 0,
            limit: 30,
            startsSmall: false,
            read: { limit in
                reads.append(limit)
                return Array(0..<min(limit, 10_000))
            },
            isIncluded: { _ in true }
        )

        #expect(page == Array(0..<30))
        #expect(reads.values == [1500])
    }

    private final class Recorder<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [Value] = []
        func append(_ value: Value) {
            lock.lock(); defer { lock.unlock() }
            recorded.append(value)
        }
        var values: [Value] {
            lock.lock(); defer { lock.unlock() }
            return recorded
        }
    }
}
