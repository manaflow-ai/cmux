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

    @Test func acceptsInputLatencyLabelsEvenWhenTheUserIsCalledTerminalOrPerson() throws {
        // A short name inside an input label must not refuse every report.
        let scanner = PrivacyLeakScanner(forbiddenTerms: HangReportFixtures.forbiddenTerms + ["Terminal", "Person", "Frames", "mina"])
        let report = InputLatencyReportTests.report(InputLatencyReportTests.fieldSnapshot())
        #expect(report.inputLatency?.isEmpty == false)
        let body = try HangReport.encoder.encode(report)
        #expect(scanner.findings(in: body).isEmpty)
    }

    @Test func aNameInsideAnInputLabelStillRefusesItElsewhere() throws {
        // Only an exact closed-set value at its own key skips the term check: "mina" (in `terminal`)
        // still makes an image named MinaTools `other`, and still refuses it planted anywhere else.
        let terms = HangReportFixtures.forbiddenTerms + ["mina"]
        let classifier = ImageClassifier(appBundlePath: HangReportFixtures.appBundle, forbiddenTerms: terms,
                                         systemImageExists: { _ in true })
        #expect(classifier.frame(metricKitName: "MinaTools.dylib", uuid: HangReportFixtures.appKitUUID, offset: 16,
                                 loaded: nil) == .other)
        let scanner = PrivacyLeakScanner(forbiddenTerms: terms)
        var report = InputLatencyReportTests.report(InputLatencyReportTests.fieldSnapshot())
        report.hangs = [HangSample(source: .watchdog, kind: .stall, durationMs: 300,
                                   frames: [HangReportFrame(image: "MinaTools.dylib", uuid: HangReportFixtures.appKitUUID, offset: 16)])]
        let found = scanner.findings(in: try HangReport.encoder.encode(report))
        #expect(found.map(\.kind) == [.personalTerm])
        #expect(found.first?.path == "$.hangs[0].frames[0].image")
        // A closed-set field holding anything but one of its members is checked too.
        report.hangs = []
        report.inputLatency?[0].target = "Mina laptop"
        let planted = scanner.findings(in: try HangReport.encoder.encode(report))
        #expect(planted.map(\.path) == ["$.input_latency[0].target"])
    }

    @Test func theInteractionKindSkipsTheTermCheckOnlyForItsOwnClosedSet() throws {
        // A person called Tap still gets `kind_of_worst: tap`; any other value there is checked.
        let scanner = PrivacyLeakScanner(forbiddenTerms: HangReportFixtures.forbiddenTerms + ["Tap"])
        var report = InputLatencyReportTests.report(InputLatencyReportTests.interactionSnapshot())
        report.interactionLatency?.kindOfWorst = "tap"
        #expect(scanner.findings(in: try HangReport.encoder.encode(report)).isEmpty)
        report.interactionLatency?.kindOfWorst = "Alice"
        let found = scanner.findings(in: try HangReport.encoder.encode(report))
        #expect(found.map(\.path) == ["$.interaction_latency.kind_of_worst"])
        #expect(found.map(\.kind) == [.personalTerm])
    }

    @Test func refusesTextThatIsNotJSON() {
        #expect(scanner.findings(in: Data("not json".utf8)).map(\.kind) == [.notJSON])
    }

    @Test func scansKeysToo() {
        let body = Data(#"{"alice@example.com": 1, "ok": "fine"}"#.utf8)
        #expect(scanner.findings(in: body).map(\.kind) == [.unsafeCharacter])
    }

    /// A blocking site id is a hash: a person whose name is hex digits (Abbe) inside one must not refuse every
    /// report, as the id stays pending and is sent again. The name is still refused
    /// anywhere else, and in the site field when the value is not a site id.
    @Test func aHexOnlyNameInsideABlockingSiteIDDoesNotRefuseTheReport() throws {
        let scanner = PrivacyLeakScanner(forbiddenTerms: HangReportFixtures.forbiddenTerms + ["Abbe"])
        let site = HangReport.BlockingSiteCount(site: "0abbe12f3c4d5e6f", kind: "file-io", count: 3, totalMs: 1)
        let report = HangReportWireFormatTests.report(.v3, blockingSites: [site])
        #expect(report.blockingSites == [site])
        #expect(scanner.findings(in: try HangReport.encoder.encode(report)).isEmpty)

        let elsewhere = Data(#"{"blocking_sites":[{"site":"0abbe12f3c4d5e6f"}],"note":"abbe"}"#.utf8)
        #expect(scanner.findings(in: elsewhere).map(\.path) == ["$.note"])
        let notAnID = Data(#"{"blocking_sites":[{"site":"abbe"},{"site":"0ABBE12F3C4D5E6F"}]}"#.utf8)
        #expect(scanner.findings(in: notAnID).map(\.path) == ["$.blocking_sites[0].site", "$.blocking_sites[1].site"])
    }
}
