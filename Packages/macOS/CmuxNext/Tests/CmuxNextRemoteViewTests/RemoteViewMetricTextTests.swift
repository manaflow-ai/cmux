@testable import CmuxNextRemoteView
import Foundation
import Testing

/// The remote desktop pane's latency text: Foundation writes the milliseconds in the pane's language, so no
/// translation carries a unit after a number (ar wrote the singular "مللي ثانية" after every count).
@MainActor
struct RemoteViewMetricTextTests {
    static let latin = Locale(identifier: "en_US@numbers=latn")

    static func milliseconds(_ value: Int, _ language: String) -> String {
        Duration.milliseconds(value).formatted(.units(allowed: [.milliseconds], width: .abbreviated)
            .locale(Locale(identifier: "\(language)_US@numbers=latn")))
    }

    @Test func theMetricIsFoundationsDuration() {
        #expect(RemoteViewStrings.milliseconds(12, preferredLocalizations: ["en"], locale: Self.latin) == "12 ms")
        let arabic = RemoteViewStrings.milliseconds(3, preferredLocalizations: ["ar"], locale: Self.latin)
        #expect(arabic == Self.milliseconds(3, "ar"))
        #expect(!arabic.contains("مللي ثانية"), "\(arabic)")
    }

    @Test func theLatencyDetailWritesBothDurations() {
        #expect(RemoteViewStrings.latencyDetail(rtt: 180, path: "direct", limit: 150, preferredLocalizations: ["en"], locale: Self.latin)
            == "180 ms, direct. Control turns off above 150 ms.")
        let arabic = RemoteViewStrings.latencyDetail(rtt: 3, path: "direct", limit: 150, preferredLocalizations: ["ar"], locale: Self.latin)
        #expect(arabic.hasPrefix(Self.milliseconds(3, "ar")), "\(arabic)")
        #expect(arabic.contains(Self.milliseconds(150, "ar")) && !arabic.contains("مللي ثانية"), "\(arabic)")
    }
}
