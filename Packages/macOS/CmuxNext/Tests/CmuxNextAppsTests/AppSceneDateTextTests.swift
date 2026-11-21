import AppKit
@testable import CmuxNextApps
import Foundation
import Testing

/// A host-ticking Text (`date`, `dateStyle`) formats as the web renderer's sceneDate.ts does, and a
/// ZStack child's `position` places its center in points or as a fraction of the stack.
@MainActor @Suite struct AppSceneDateTextTests {
    private let en = Locale(identifier: "en_US")
    // 2026-11-16 17:41:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_794_850_860)

    @Test func timerCountsDownToAFutureDateAndUpFromAPastOne() {
        let soon = AppSceneDateText(style: .timer, date: now.addingTimeInterval(245))
        #expect(soon.text(at: now, locale: en) == "4:05")
        let long = AppSceneDateText(style: .timer, date: now.addingTimeInterval(-3723))
        #expect(long.text(at: now, locale: en) == "1:02:03")
        #expect(soon.text(at: now.addingTimeInterval(245.9), locale: en) == "0:00")
    }

    @Test func timeAndDateUseTheTextsZone() {
        let zone = TimeZone(identifier: "America/Los_Angeles")
        // Newer ICU puts a narrow no-break space before AM.
        let time = AppSceneDateText(style: .time, date: now, timeZone: zone).text(at: now, locale: en)
        #expect(time.replacingOccurrences(of: "\u{202F}", with: " ") == "9:41 AM")
        #expect(AppSceneDateText(style: .date, date: now, timeZone: zone).text(at: now, locale: en) == "November 16, 2026")
    }

    @Test func offsetIsSignedInItsLargestUnit() {
        #expect(AppSceneDateText(style: .offset, date: now.addingTimeInterval(7200), timeZone: nil).text(at: now, locale: en) == "+2 hours")
        #expect(AppSceneDateText(style: .offset, date: now.addingTimeInterval(-180)).text(at: now, locale: en) == "-3 minutes")
    }

    @Test func aNodeIsATickingTextOnlyWithAFiniteDate() {
        let node = AppSceneNode(type: .text, props: ["date": .number(1_794_850_860_000), "dateStyle": .string("timer")])
        #expect(AppSceneDateText(node)?.style == .timer)
        #expect(AppSceneDateText(AppSceneNode(type: .text, props: ["date": .number(1), "dateStyle": .string("bogus")]))?.style == .time)
        #expect(AppSceneDateText(AppSceneNode(type: .text, props: ["text": .string("9:41")])) == nil)
    }

    @Test func positionPlacesTheCenterInPointsOrAFraction() {
        let rect = CGRect(x: 10, y: 20, width: 200, height: 100)
        #expect(AppScenePosition(x: 30, y: 40, fraction: false).center(in: rect) == CGPoint(x: 40, y: 60))
        #expect(AppScenePosition(x: nil, y: 0.25, fraction: true).center(in: rect) == CGPoint(x: 110, y: 45))
    }
}
