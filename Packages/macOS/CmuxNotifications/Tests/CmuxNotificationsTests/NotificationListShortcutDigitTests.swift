import CmuxNotifications
import Testing

@Suite struct NotificationListShortcutDigitTests {
    @Test func digitsSelectRowsInOrderAndNineSelectsTheLast() {
        let numbering = NotificationListShortcutDigit(rowCount: 12)
        #expect(numbering.rowIndex(forDigit: 1) == 0)
        #expect(numbering.rowIndex(forDigit: 8) == 7)
        #expect(numbering.rowIndex(forDigit: 9) == 11)
    }

    @Test func aDigitPastTheListSelectsNothing() {
        let numbering = NotificationListShortcutDigit(rowCount: 3)
        #expect(numbering.rowIndex(forDigit: 4) == nil)
        #expect(numbering.rowIndex(forDigit: 9) == 2)
        #expect(numbering.rowIndex(forDigit: 0) == nil)
        #expect(numbering.rowIndex(forDigit: 10) == nil)
        #expect(NotificationListShortcutDigit(rowCount: 0).rowIndex(forDigit: 9) == nil)
    }

    @Test func eachRowShowsTheDigitThatSelectsIt() {
        for count in [1, 3, 8, 9, 12] {
            let numbering = NotificationListShortcutDigit(rowCount: count)
            for index in 0..<count {
                guard let digit = numbering.digit(forRowIndex: index) else { continue }
                #expect(numbering.rowIndex(forDigit: digit) == index, "count \(count) row \(index) shows \(digit)")
            }
        }
    }

    @Test func rowsBetweenTheEighthAndTheLastShowNoDigit() {
        let numbering = NotificationListShortcutDigit(rowCount: 12)
        #expect(numbering.digit(forRowIndex: 7) == 8)
        #expect(numbering.digit(forRowIndex: 8) == nil)
        #expect(numbering.digit(forRowIndex: 10) == nil)
        #expect(numbering.digit(forRowIndex: 11) == 9)
        #expect(NotificationListShortcutDigit(rowCount: 9).digit(forRowIndex: 8) == 9)
    }
}
