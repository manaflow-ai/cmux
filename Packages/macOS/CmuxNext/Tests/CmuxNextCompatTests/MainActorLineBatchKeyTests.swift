import CmuxNextCompat
import Testing

/// ``MainActorLineBatch`` with a `key`: a value replaces the pending one of its key, which takes the
/// new one's place at the end, so a burst of pushes of a few busy chats is one value per chat and
/// never overflows. Every overflow made the turn-state feed read the whole session list again
/// (31 MB on one Mac, 2026-11-11).
@MainActor @Suite struct MainActorLineBatchKeyTests {
    @MainActor final class Log {
        var drains: [MainActorLineDrain<String>] = []
        var waiter: CheckedContinuation<Void, Never>?
    }

    private func batch(limit: Int, log: Log) -> MainActorLineBatch<String> {
        MainActorLineBatch<String>(limit: limit, key: { $0.hasPrefix("chat") ? String($0.prefix(5)) : nil }) { drain in
            log.drains.append(drain)
            log.waiter?.resume()
            log.waiter = nil
        }
    }

    @Test func aKeysRepeatsWhilePendingAreItsNewestAloneInItsNewPlace() async {
        let log = Log()
        let lines = batch(limit: 4, log: log)
        await withCheckedContinuation { waiter in
            log.waiter = waiter
            for value in ["chatA1", "purge", "chatB1", "chatA2", "chatA3", "chatB2", "chatA4"] { lines.submit(value) }
        }
        #expect(log.drains.count == 1)
        #expect(log.drains.first?.values == ["purge", "chatB2", "chatA4"])
        #expect(log.drains.first?.overflowed == false)
    }

    @Test func manyPushesOfAFewChatsNeverOverflow() async {
        let log = Log()
        let lines = batch(limit: 4, log: log)
        await withCheckedContinuation { waiter in
            log.waiter = waiter
            for n in 0..<10_000 { lines.submit("chat\(["A", "B", "C"][n % 3])\(n)") }
        }
        #expect(log.drains.first?.values == ["chatB9997", "chatC9998", "chatA9999"])
        #expect(log.drains.first?.overflowed == false)
    }

    @Test func valuesWithNoKeyStillOverflowPastTheLimit() async {
        let log = Log()
        let lines = batch(limit: 4, log: log)
        await withCheckedContinuation { waiter in
            log.waiter = waiter
            for n in 0..<6 { lines.submit("line\(n)") }
        }
        #expect(log.drains.first?.values == ["line0", "line1", "line2", "line3"])
        #expect(log.drains.first?.overflowed == true)
    }
}
