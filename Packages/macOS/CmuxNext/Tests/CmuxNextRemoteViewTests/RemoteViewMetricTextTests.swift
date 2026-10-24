@testable import CmuxNextRemoteView
import Foundation
import Testing

/// The remote desktop pane's latency text: Foundation writes the milliseconds in the pane's language, so no
/// translation carries a unit after a number (ar wrote the singular "مللي ثانية" after every count).
@MainActor
struct RemoteViewMetricTextTests {
    static let latin = Locale(identifier: "en_US@numbers=latn")

    /// `text` as a `%@` argument reads inside a sentence that holds right-to-left text: Foundation's
    /// `String(format:locale:)` writes it between U+2068 FIRST STRONG ISOLATE and U+2069 POP DIRECTIONAL ISOLATE
    /// (see `Bundle.localizedString(forKey:value:table:arguments:preferredLocalizations:locale:)`).
    static func isolated(_ text: String) -> String { "\u{2068}\(text)\u{2069}" }

    /// Whether `text` holds `part` exactly: a literal search, so a Latin "3" never matches an Arabic-Indic "٣" (the
    /// default `contains` on a bridged `String(format:)` result is not literal).
    static func holds(_ text: String, _ part: String) -> Bool { text.range(of: part, options: .literal) != nil }

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
        #expect(arabic.hasPrefix(Self.isolated(Self.milliseconds(3, "ar")) + "، " + Self.isolated("direct")), "\(arabic)")
        #expect(Self.holds(arabic, Self.isolated(Self.milliseconds(150, "ar"))) && !arabic.contains("مللي ثانية"), "\(arabic)")
    }
}
