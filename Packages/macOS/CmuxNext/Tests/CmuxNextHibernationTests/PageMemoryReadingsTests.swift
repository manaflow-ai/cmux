import CmuxNextHibernation
import Testing

/// ``PageMemoryReadings``: one sample at a time replaces every reading, another sampler's readings
/// change only live pages it measured, and a reading counts as now for ``PageMemoryReadings/maxAge``.
@Suite struct PageMemoryReadingsTests {
    let start = ContinuousClock.now

    @Test func oneSampleRunsAtATimeAndReplacesEveryReading() {
        var readings = PageMemoryReadings()
        let first = readings.begin(), second = readings.begin()
        #expect(first)
        #expect(!second, "a second sample started while one ran")
        readings.land(["a": PageMemoryReading(bytes: 10, sharers: ["a", "b"])], at: start)
        #expect(!readings.isMeasuring)
        #expect(readings.reading("a") == PageMemoryReading(bytes: 10, sharers: ["a", "b"]))
        let next = readings.begin()
        #expect(next)
        readings.land(["b": PageMemoryReading(bytes: 20, sharers: ["b"])], at: start)
        #expect(readings.reading("a") == nil, "a sample kept a page it did not measure")
        #expect(readings.bytes == ["b": 20])
    }

    @Test func anotherSamplersReadingsChangeOnlyLivePagesWithANumber() {
        var readings = PageMemoryReadings()
        readings.land(["a": PageMemoryReading(bytes: 10, sharers: ["a"])], at: start)
        readings.note(["a": PageMemoryReading(bytes: 0, sharers: ["a"]), "gone": PageMemoryReading(bytes: 5, sharers: ["gone"])],
                      at: start + .seconds(40)) { $0 != "gone" }
        #expect(readings.bytes == ["a": 10], "a reading of nothing or of a closed page changed a number")
        #expect(readings.isFresh(at: start + .seconds(41)), "the other sampler's reading did not count as now")
        readings.forget("a")
        #expect(readings.reading("a") == nil)
    }

    @Test func aReadingCountsAsNowForItsMaxAge() {
        var readings = PageMemoryReadings()
        #expect(!readings.isFresh(at: start))
        readings.land([:], at: start)
        #expect(readings.isFresh(at: start + .seconds(29)))
        #expect(!readings.isFresh(at: start + PageMemoryReadings.maxAge))
    }
}
