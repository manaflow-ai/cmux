import Foundation
import Testing
@testable import CmuxConversationCore

@Suite struct ConversationShortTimeTests {
    /// A formatter that counts its calls.
    final class Counting: @unchecked Sendable {
        var calls = 0
        func format(_ date: Date) -> String {
            calls += 1
            return date.formatted(date: .omitted, time: .shortened)
        }
    }

    @Test func eachMinuteIsFormattedOnce() {
        let counting = Counting()
        var cache = ConversationShortTimeCache(format: counting.format)
        let minute = Date(timeIntervalSinceReferenceDate: 800_000_040)
        for second in 0..<60 {
            _ = cache.text(for: minute.addingTimeInterval(Double(second) + 0.25))
        }
        _ = cache.text(for: minute.addingTimeInterval(60))
        _ = cache.text(for: minute)
        #expect(counting.calls == 2)
    }

    @Test func textsMatchTheSystemFormat() {
        var cache = ConversationShortTimeCache()
        var date = Date(timeIntervalSinceReferenceDate: 790_000_000)
        for step in 0..<500 {
            date = date.addingTimeInterval(Double(step * 37 % 997) + 0.5)
            #expect(cache.text(for: date) == date.formatted(date: .omitted, time: .shortened))
            #expect(cache.text(for: date) == date.formatted(date: .omitted, time: .shortened))
        }
    }

    @Test func oldDatesAreFormattedEachTime() {
        let counting = Counting()
        var cache = ConversationShortTimeCache(format: counting.format)
        let old = Date(timeIntervalSince1970: -1_000_000_000)
        _ = cache.text(for: old)
        _ = cache.text(for: old.addingTimeInterval(1))
        #expect(counting.calls == 2)
    }

    @Test func removeAllFormatsAgain() {
        let counting = Counting()
        var cache = ConversationShortTimeCache(format: counting.format)
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        _ = cache.text(for: date)
        cache.removeAll()
        _ = cache.text(for: date)
        #expect(counting.calls == 2)
    }

    /// The system posts the locale and time zone changes on any thread; the
    /// shared cache still empties, on the main actor (strict-4).
    @MainActor @Test func aLocaleChangePostedOffMainEmptiesTheSharedCache() async {
        _ = ConversationShortTime.text(for: Date(timeIntervalSinceReferenceDate: 800_000_000))
        #expect(ConversationShortTime.cache.count > 0)
        await withCheckedContinuation { (posted: CheckedContinuation<Void, Never>) in
            DispatchQueue(label: "ConversationShortTimeTests.poster", qos: .utility).async {
                NotificationCenter.default.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
                posted.resume()
            }
        }
        // The emptying task was queued on the main actor before this test resumed.
        for _ in 0..<100 where ConversationShortTime.cache.count > 0 { await Task.yield() }
        #expect(ConversationShortTime.cache.count == 0)
    }
}
