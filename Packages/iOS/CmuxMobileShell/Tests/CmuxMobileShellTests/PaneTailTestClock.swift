import Foundation

@MainActor
final class PaneTailTestClock {
    var date: Date

    init(_ date: Date) {
        self.date = date
    }

    func advance(by interval: TimeInterval) {
        date = date.addingTimeInterval(interval)
    }
}
