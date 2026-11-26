import Foundation

protocol SudoBrokerClock: Sendable {
    func now() async -> Date
    func sleep(until deadline: Date) async throws
}
