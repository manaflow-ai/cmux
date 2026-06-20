import Foundation

actor AuthPhaseTimeoutRace {
    private var hasWinner = false

    func winOperation() -> Bool {
        win()
    }

    func winTimeout() -> Bool {
        win()
    }

    private func win() -> Bool {
        guard !hasWinner else { return false }
        hasWinner = true
        return true
    }
}
