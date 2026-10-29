import Foundation
import Testing
@testable import CmuxMobileRPC

/// The date parser is a plain `Sendable` value (two `Date.ISO8601FormatStyle`s) and the
/// timeout cancellation bridge keeps its state in a `Mutex`. Run under
/// TSan (`swift test --sanitize=thread`) too.
@Suite("Mobile RPC Sendable state")
struct MobileRPCSendableStateTests {
    /// The forms `ISO8601DateFormatter` (whole seconds, then fractional) accepted before.
    @Test("The parser accepts and rejects what the formatter pair did")
    func parserKeepsTheFormatterPairsForms() throws {
        let parser = MobileRPCISO8601DateParser()
        let accepted: [(String, TimeInterval)] = [
            ("2026-09-30T22:44:53Z", 1_790_808_293),
            ("2026-09-30T22:44:53.481Z", 1_790_808_293.481),
            ("2026-09-30T22:44:53.1Z", 1_790_808_293.1),
            ("2026-09-27T14:05:00.250Z", 1_790_517_900.25),
            ("2026-09-30T22:44:53+02:00", 1_790_801_093),
            ("2026-09-30T22:44:53-07:00", 1_790_833_493),
            ("2026-09-30T22:44:53.481+05:30", 1_790_788_493.481),
            ("1970-01-01T00:00:00Z", 0),
        ]
        for (raw, seconds) in accepted {
            let date = try #require(parser.date(from: raw), "\(raw)")
            #expect(abs(date.timeIntervalSince1970 - seconds) < 0.0005, "\(raw)")
        }
        for raw in ["2026-09-30T22:44:53", "2026-09-30", "yesterday", "", "2026-09-30T22:44:53.Z", "2026-13-30T22:44:53Z"] {
            #expect(parser.date(from: raw) == nil, "\(raw)")
        }
    }

    @Test("One parser is shared across concurrent decodes")
    func parserIsSharedAcrossTasks() async {
        let parser = MobileRPCISO8601DateParser()
        let parsed = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    (0..<200).reduce(0) { count, _ in
                        parser.date(from: "2026-09-30T22:44:53.481Z") == nil ? count : count + 1
                    }
                }
            }
            return await group.reduce(0, +)
        }
        #expect(parsed == 1_600)
    }

    @Test("A cancel racing install finishes the stream once, with CancellationError")
    func cancelRacingInstallFinishesOnce() async {
        for _ in 0..<200 {
            let race = RPCTaskTimeoutRace()
            let cancellation = RPCTaskTimeoutCancellation<Int>()
            let (stream, continuation) = AsyncThrowingStream<Int, any Error>.makeStream()
            await withTaskGroup(of: Void.self) { group in
                group.addTask { cancellation.install(continuation, race: race) }
                group.addTask { cancellation.cancel(race: race) }
                group.addTask { cancellation.cancel(race: race) }
            }
            var finishedWithCancellation = false
            do {
                for try await _ in stream {}
            } catch is CancellationError {
                finishedWithCancellation = true
            } catch {}
            #expect(finishedWithCancellation)
            // The cancellation won the race, so no other path may finish the stream.
            #expect(await race.win() == false)
        }
    }

    @Test("A timeout cancelled by its caller throws CancellationError")
    func cancelledTimeoutThrowsCancellation() async {
        let timeout = RPCTaskTimeout(sleep: { _ in try await Task.sleep(for: .seconds(30)) })
        let work = Task<Int, any Error> { try await Task.sleep(for: .seconds(30)); return 1 }
        let caller = Task { try await timeout.value(work, timeoutNanoseconds: 30_000_000_000) }
        caller.cancel()
        await #expect(throws: CancellationError.self) { try await caller.value }
        work.cancel()
    }
}
