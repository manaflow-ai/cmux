@testable import CmuxSudoBroker
import Foundation

actor TestSudoClock: SudoBrokerClock {
    private struct Sleeper {
        let deadline: Date
        let continuation: AsyncStream<Void>.Continuation
    }

    var date: Date
    private var sleepers: [UUID: Sleeper] = [:]

    init(date: Date) {
        self.date = date
    }

    func now() async -> Date { date }

    func sleep(until deadline: Date) async throws {
        guard deadline > date else { return }
        let id = UUID()
        let pair = AsyncStream.makeStream(of: Void.self)
        sleepers[id] = Sleeper(
            deadline: deadline,
            continuation: pair.continuation
        )
        defer {
            sleepers.removeValue(forKey: id)
            pair.continuation.finish()
        }
        for await _ in pair.stream {}
        try Task.checkCancellation()
    }

    func advance(to newDate: Date) {
        date = newDate
        let ready = sleepers.compactMap { id, sleeper in
            sleeper.deadline <= newDate ? id : nil
        }
        for id in ready {
            sleepers.removeValue(forKey: id)?.continuation.finish()
        }
    }
}
