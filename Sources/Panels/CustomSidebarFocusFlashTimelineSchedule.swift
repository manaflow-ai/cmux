import Foundation
import SwiftUI

struct CustomSidebarFocusFlashTimelineSchedule: TimelineSchedule {
    let startDate: Date

    func entries(from requestedStartDate: Date, mode: Mode) -> Entries {
        let firstDate = requestedStartDate > startDate ? requestedStartDate : startDate
        let interval = mode == .lowFrequency ? 1.0 / 10.0 : 1.0 / 60.0
        return Entries(
            nextDate: firstDate,
            endDate: startDate.addingTimeInterval(FocusFlashPattern.duration),
            interval: interval
        )
    }

    struct Entries: Sequence, IteratorProtocol {
        var nextDate: Date
        let endDate: Date
        let interval: TimeInterval

        mutating func next() -> Date? {
            guard nextDate <= endDate else { return nil }
            let date = nextDate
            nextDate = nextDate.addingTimeInterval(interval)
            return date
        }
    }
}
