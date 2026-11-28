import Foundation

actor RPCTaskTimeoutRace {
    private var hasWinner = false

    func win() -> Bool {
        guard !hasWinner else { return false }
        hasWinner = true
        return true
    }
}
