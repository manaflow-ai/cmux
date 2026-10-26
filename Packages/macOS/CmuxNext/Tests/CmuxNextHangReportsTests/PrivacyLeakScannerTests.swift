@testable import CmuxNextHangReports
import Foundation
import Testing

/// The last check refuses a report that carries any kind of private string, and names only the
/// JSON path of what it found, never the value.
struct PrivacyLeakScannerTests {
    private let scanner = PrivacyLeakScanner(forbiddenTerms: HangReportFixtures.forbiddenTerms + ["cmux"])

    private func findings(planting value: String, at key: String = "image") -> [PrivacyLeakScanner.Finding] {
        var report = HangReportFixtures.builder().build(context: HangReportFixtures.context(), watchdog: StallAggregate(), metricKit: [])
        report.hangs = [HangSample(source: .watchdog, kind: .stall, durationMs: 300,
                                   frames: [HangReportFrame(image: key == "image" ? value : "AppKit", uuid: key == "uuid" ? value : nil, offset: 1)])]
        return scanner.findings(in: (try? HangReport.encoder.encode(report)) ?? Data())
    }

    @Test(arguments: [
        ("/Users/alice/Library/Input Methods/X.app", PrivacyLeakScanner.Kind.unsafeCharacter),
        ("~/Desktop", .unsafeCharacter),
        ("bob@example.com", .unsafeCharacter),
        ("https://intranet.example.com", .unsafeCharacter),
        ("10.0.0.12:22", .unsafeCharacter),
        ("fe80::1", .unsafeCharacter),
        ("HOME=x", .unsafeCharacter),
        ("\"quoted\"", .unsafeCharacter),
        ("ghpA1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8", .token),
        ("Alice", .personalTerm),
        ("Report for Alices-MacBook-Pro", .personalTerm),
        (String(repeating: "a", count: 200), .tooLong),
    ])
    func refusesEachKindOfPrivateString(value: String, kind: PrivacyLeakScanner.Kind) throws {
        let found = findings(planting: value)
        let first = try #require(found.first)
        #expect(first.kind == kind)
        #expect(first.path == "$.hangs[0].frames[0].image")
        #expect(!first.description.contains(value))
    }

    @Test func acceptsUUIDsVersionsBucketsAndOurOwnNameEvenWhenTheUserIsCalledCmux() {
        #expect(findings(planting: "cmux NEXT Nightly").isEmpty)
        #expect(findings(planting: "libswiftCore.dylib").isEmpty)
        #expect(findings(planting: "Chromium Embedded Framework").isEmpty)
        #expect(findings(planting: HangReportFixtures.appUUID, at: "uuid").isEmpty)
    }

    @Test func interactionLatencyIsNumbersAndAClosedKindAndPassesTheScan() throws {
        let builder = HangReportFixtures.builder()
        let interactions = HangReport.InteractionLatency(count: 120, worstMs: 300.04, highPctMs: 40.26, kindOfWorst: "key")
        let report = builder.build(context: HangReportFixtures.context(), watchdog: StallAggregate(), metricKit: [],
                                   interactions: interactions)
        #expect(report.interactionLatency == HangReport.InteractionLatency(count: 120, worstMs: 300, highPctMs: 40.3,
                                                                           kindOfWorst: "key"))
        let body = try HangReport.encoder.encode(report)
        #expect(scanner.findings(in: body).isEmpty)
        #expect(String(decoding: body, as: UTF8.self)
            .contains(#""interactionLatency":{"count":120,"highPctMs":40.3,"kindOfWorst":"key","worstMs":300}"#))

        // Anything outside the closed set, or not a finite duration, never reaches the wire.
        for unsafe in [
            HangReport.InteractionLatency(count: 3, worstMs: 9, highPctMs: 9, kindOfWorst: "/Users/alice"),
            HangReport.InteractionLatency(count: 0, worstMs: 9, highPctMs: 9, kindOfWorst: "key"),
            HangReport.InteractionLatency(count: 3, worstMs: .nan, highPctMs: 9, kindOfWorst: "tap"),
            HangReport.InteractionLatency(count: 3, worstMs: 9, highPctMs: -1, kindOfWorst: "drag"),
        ] {
            let built = builder.build(context: HangReportFixtures.context(), watchdog: StallAggregate(), metricKit: [],
                                      interactions: unsafe)
            #expect(built.interactionLatency == nil)
        }
        let none = builder.build(context: HangReportFixtures.context(), watchdog: StallAggregate(), metricKit: [])
        let noneBody = try HangReport.encoder.encode(none)
        #expect(!String(decoding: noneBody, as: UTF8.self).contains("interactionLatency"))
    }

    @Test func refusesTextThatIsNotJSON() {
        #expect(scanner.findings(in: Data("not json".utf8)).map(\.kind) == [.notJSON])
    }

    @Test func scansKeysToo() {
        let body = Data(#"{"alice@example.com": 1, "ok": "fine"}"#.utf8)
        #expect(scanner.findings(in: body).map(\.kind) == [.unsafeCharacter])
    }
}
