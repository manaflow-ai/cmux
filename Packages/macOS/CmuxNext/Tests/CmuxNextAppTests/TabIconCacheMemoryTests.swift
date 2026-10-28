import AppKit
import CmuxNextCompat
import CmuxNextIcons
@testable import CmuxNextTabs
import CmuxNextWakeupsTestSupport
import Testing

/// The tab strips' drawn icon caches (tinted symbols, icon pack images, agent marks, user
/// emoji, known symbol names) were dictionaries emptied whole at 257 entries, outside the memory
/// coordinator. Each is now a lossless ``TabImageMemo`` consumer: a new limit frees nothing, a release frees
/// idle values least recently used first, at limit 0 an idle memo holds 0 values and 0 bytes, values drawn in
/// the last 2 s stay, and a hit after a release draws again.
@MainActor @Suite struct TabIconCacheMemoryTests {
    /// A registry that hands each new consumer `limit` at once, as the coordinator does.
    @MainActor private final class FakeRegistry: MemoryConsumerRegistry {
        var limit = MemoryLimit.default
        var entries: [MemoryConsumerEntry] = []

        func addMemoryConsumer(_ entry: MemoryConsumerEntry) {
            entries.append(entry)
            entry.liveConsumer?.updateMemoryLimit(limit)
        }
    }

    private static let side = 8

    /// One 8 x 8 RGBA picture: 256 bytes.
    private static func image() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try #require(context.makeImage())
    }

    private static func slice(_ percent: Int, expired: Bool = false) -> MemoryReleaseSlice {
        MemoryReleaseSlice(limit: MemoryLimit(percent: percent)) { expired }
    }

    /// A memo of `count` images, key 0 the least recently used, with `draws` counting each draw.
    @MainActor private final class Filled {
        let clock = ManualClock()
        let memo: TabImageMemo<CGImage>
        var draws = 0

        init(_ count: Int, capacity: Int = 8) throws {
            memo = TabImageMemo(name: "test-images", capacity: capacity, bytes: TabImageMemo<CGImage>.pixelBytes(_:), clock: clock)
            for index in 0..<count { _ = try get(index) }
        }

        func get(_ index: Int) throws -> CGImage? {
            let image = try TabIconCacheMemoryTests.image()
            return memo.value(for: "k\(index)") {
                draws += 1
                return image
            }
        }

        /// Moves the clock past the in-use window, so every value is idle.
        func idle() {
            clock.advance(by: TabImageMemo<CGImage>.inUse * 2)
        }
    }

    @Test func traitsAreSmallLosslessCheapAndManaged() {
        let traits = TabImageMemo<CGImage>.memoryTraits
        #expect(traits.estimatedUsage == .small)
        #expect(traits.dataAccess == .none)
        #expect(traits.retention == .lossless)
        #expect(traits.recreateCost == .cheap)
        #expect(traits.isManaged)
    }

    @Test func usageCountsPixelBytesAndEntries() throws {
        let filled = try Filled(3)
        #expect(filled.memo.memoryUsage == MemoryUsage(footprintBytes: 3 * Self.side * Self.side * 4, entries: 3))
    }

    @Test func aHitDrawsNothing() throws {
        let filled = try Filled(2)
        _ = try filled.get(0)
        _ = try filled.get(1)
        #expect(filled.draws == 2)
    }

    @Test func aNewLimitFreesNothing() throws {
        let filled = try Filled(4)
        filled.memo.updateMemoryLimit(MemoryLimit(percent: 0))
        #expect(filled.memo.count == 4)
    }

    @Test func aReleaseAtLimitZeroLeavesNoIdleValueAndAHitDrawsAgain() throws {
        let filled = try Filled(4)
        filled.idle()
        #expect(filled.memo.releaseMemory(within: Self.slice(0)) == .done)
        #expect(filled.memo.memoryUsage == .empty)
        #expect(try filled.get(0) != nil)
        #expect(filled.draws == 5, "a hit after the release draws again")
    }

    @Test func aReleaseKeepsValuesDrawnInTheLastTwoSeconds() throws {
        let filled = try Filled(3)
        filled.idle()
        _ = try filled.get(2)
        #expect(filled.memo.releaseMemory(within: Self.slice(0)) == .done)
        #expect(filled.memo.count == 1, "the value in use stays")
        _ = try filled.get(2)
        #expect(filled.draws == 3, "the kept value is a hit")
        filled.idle()
        #expect(filled.memo.releaseMemory(within: Self.slice(0)) == .done)
        #expect(filled.memo.count == 0, "once idle it goes too")
    }

    @Test func aReleaseDropsLeastRecentlyUsedFirst() throws {
        let filled = try Filled(4, capacity: 4)
        _ = try filled.get(0)  // now 1 is the oldest, then 2, 3, 0
        filled.idle()
        #expect(filled.memo.releaseMemory(within: Self.slice(50)) == .done)
        #expect(filled.memo.count == 2)
        _ = try filled.get(3)
        _ = try filled.get(0)
        #expect(filled.draws == 4, "3 and 0, the most recently used, stayed")
    }

    @Test func anExpiredSliceAsksForMore() throws {
        let filled = try Filled(3)
        filled.idle()
        #expect(filled.memo.releaseMemory(within: Self.slice(0, expired: true)) == .more)
        #expect(filled.memo.count == 3)
    }

    @Test func underALoweredLimitAnInsertDropsIdleValues() throws {
        let filled = try Filled(4)
        filled.idle()
        filled.memo.updateMemoryLimit(MemoryLimit(percent: 0))
        _ = try filled.get(9)
        #expect(filled.memo.count == 1, "the idle values went; the new one is in use")
    }

    @Test func theMemoNeverHoldsMoreThanItsCapacity() throws {
        let filled = try Filled(6, capacity: 4)
        #expect(filled.memo.count == 4, "over capacity the oldest goes even when in use")
        _ = try filled.get(0)
        #expect(filled.draws == 7, "key 0 was the oldest")
    }

    @Test func drawFailuresAreNotKept() throws {
        let memo = TabImageMemo<CGImage>(name: "test-images", capacity: 4, bytes: TabImageMemo<CGImage>.pixelBytes(_:), clock: ManualClock())
        var draws = 0
        for _ in 0..<2 {
            let drawn = memo.value(for: "missing") {
                draws += 1
                return nil
            }
            #expect(drawn == nil)
        }
        #expect(draws == 2)
        #expect(memo.count == 0)
    }

    @Test func registeringAddsEveryTabIconCacheAndHandsItTheLimit() throws {
        let clock = ManualClock()
        let symbols = TabSymbolCache(clock: clock), packIcons = TabPackIconCache(clock: clock)
        let agentMarks = TabAgentMarkCache(clock: clock), userIcons = TabUserIconImages(clock: clock)
        let registry = FakeRegistry()
        registry.limit = MemoryLimit(percent: 50)
        TabIconMemoryConsumers(registry: registry, symbols: symbols, packIcons: packIcons, agentMarks: agentMarks,
                               userIcons: userIcons).register()
        #expect(registry.entries.map(\.name) == ["tab-symbol-images", "tab-pack-icons", "tab-agent-marks",
                                                 "tab-user-emoji", "tab-user-symbol-names"])
        #expect(symbols.images.countLimit == 128)
        #expect(userIcons.symbolNames.countLimit == 128)
    }

    @Test func theSymbolCacheDrawsAgainAfterACriticalRelease() throws {
        let clock = ManualClock()
        let symbols = TabSymbolCache(clock: clock)
        let first = try #require(symbols.image(named: "pin.fill", tint: .black, pointSize: 10, size: 16, scale: 2))
        #expect(symbols.image(named: "pin.fill", tint: .black, pointSize: 10, size: 16, scale: 2) === first, "a hit")
        #expect(symbols.images.memoryUsage == MemoryUsage(footprintBytes: TabImageMemo<CGImage>.pixelBytes(first), entries: 1))
        clock.advance(by: TabImageMemo<CGImage>.inUse * 2)
        #expect(symbols.images.releaseMemory(within: Self.slice(0)) == .done)
        #expect(symbols.images.memoryUsage == .empty)
        let again = try #require(symbols.image(named: "pin.fill", tint: .black, pointSize: 10, size: 16, scale: 2))
        #expect(again !== first, "a hit after the release draws again")
    }

    @Test func thePackIconCacheDrawsAgainAfterACriticalRelease() throws {
        let clock = ManualClock()
        let icons = TabPackIconCache(clock: clock)
        let first = try #require(icons.image(name: .terminal, tint: .black, size: 16, scale: 2))
        #expect(icons.image(name: .terminal, tint: .black, size: 16, scale: 2) === first, "a hit")
        clock.advance(by: TabImageMemo<CGImage>.inUse * 2)
        #expect(icons.images.releaseMemory(within: Self.slice(0)) == .done)
        #expect(icons.images.memoryUsage == .empty)
        #expect(icons.image(name: .terminal, tint: .black, size: 16, scale: 2) !== first, "a hit after the release draws again")
    }

    @Test func theAgentMarkCacheDrawsAgainAfterACriticalRelease() throws {
        let clock = ManualClock()
        let marks = TabAgentMarkCache(clock: clock)
        // "claude" is a brand in AgentBrandCatalog; the cache takes the brand's raw ID.
        let first = try #require(marks.image(brand: "claude", tint: .black, size: 16, scale: 2))
        #expect(marks.image(brand: "claude", tint: .black, size: 16, scale: 2) === first, "a hit")
        #expect(marks.images.memoryUsage == MemoryUsage(footprintBytes: TabImageMemo<CGImage>.pixelBytes(first), entries: 1))
        clock.advance(by: TabImageMemo<CGImage>.inUse * 2)
        #expect(marks.images.releaseMemory(within: Self.slice(0)) == .done)
        #expect(marks.images.memoryUsage == .empty)
        let again = try #require(marks.image(brand: "claude", tint: .black, size: 16, scale: 2))
        #expect(again !== first, "a hit after the release draws again")
    }

    @Test func userEmojiAndSymbolNamesAreReleasedAndComeBack() throws {
        let clock = ManualClock()
        let icons = TabUserIconImages(clock: clock)
        let first = try #require(icons.emoji("🦊"))
        #expect(icons.emoji("🦊") === first, "a hit keeps the image's identity")
        #expect(icons.draws(symbol: "pin.fill"))
        #expect(icons.symbolNames.count == 1)
        clock.advance(by: TabImageMemo<CGImage>.inUse * 2)
        #expect(icons.emojiImages.releaseMemory(within: Self.slice(0)) == .done)
        #expect(icons.symbolNames.releaseMemory(within: Self.slice(0)) == .done)
        #expect(icons.emojiImages.memoryUsage == .empty)
        #expect(icons.symbolNames.memoryUsage == .empty)
        #expect(icons.emoji("🦊") !== first, "a hit after the release draws again")
        #expect(icons.draws(symbol: "pin.fill"))
    }
}
