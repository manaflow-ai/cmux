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

    @Test func refusesTextThatIsNotJSON() {
        #expect(scanner.findings(in: Data("not json".utf8)).map(\.kind) == [.notJSON])
    }

    @Test func scansKeysToo() {
        let body = Data(#"{"alice@example.com": 1, "ok": "fine"}"#.utf8)
        #expect(scanner.findings(in: body).map(\.kind) == [.unsafeCharacter])
    }
}
