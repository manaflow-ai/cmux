@testable import CmuxSudoBroker
import Foundation

actor TestSudoClock: SudoBrokerClock {
    var date: Date

    init(date: Date) {
        self.date = date
    }

    func now() async -> Date { date }
}

