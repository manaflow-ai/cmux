import Foundation
import Testing
@testable import CmuxBrowser

struct BrowserPageStateCaptureTests {
    private let state = Data(repeating: 0xAB, count: 64)

    private func capture(
        state: Data?,
        coversNavigationHistory: Bool = true,
        containsFormSubmission: Bool = false
    ) -> BrowserPageStateCapture {
        BrowserPageStateCapture(
            interactionState: state,
            documentURL: URL(string: "https://example.com/"),
            coversNavigationHistory: coversNavigationHistory,
            containsFormSubmission: containsFormSubmission
        )
    }

    @Test("State covering the pane's history without form submissions persists")
    func persistsCleanState() {
        #expect(capture(state: state).persistableInteractionState() == state)
    }

    @Test("State holding a form submission never persists")
    func dropsFormSubmission() {
        #expect(capture(state: state, containsFormSubmission: true).persistableInteractionState() == nil)
    }

    @Test("State that replays restored URL history does not persist")
    func dropsPartialHistory() {
        #expect(capture(state: state, coversNavigationHistory: false).persistableInteractionState() == nil)
    }

    @Test("Missing, empty and oversized state does not persist")
    func dropsEmptyAndOversizedState() {
        #expect(capture(state: nil).persistableInteractionState() == nil)
        #expect(capture(state: Data()).persistableInteractionState() == nil)
        #expect(capture(state: state).persistableInteractionState(maxBytes: 63) == nil)
        #expect(capture(state: state).persistableInteractionState(maxBytes: 64) == state)
    }
}

struct BrowserFormStateSnapshotTests {
    @Test("Parses text, checkbox and select fields from an observer report")
    func parsesReport() throws {
        let body: [String: Any] = [
            "url": "https://example.com/compose",
            "fields": [
                ["k": "id:subject", "v": "Hello"],
                ["k": "name:0:urgent:0", "c": true],
                ["k": "path:body:0/select:2", "s": [NSNumber(value: 1), NSNumber(value: 3)]]
            ] as [[String: Any]]
        ]
        let snapshot = try #require(BrowserFormStateSnapshot(messageBody: body))
        #expect(snapshot.documentURL == URL(string: "https://example.com/compose"))
        #expect(snapshot.fields == [
            .init(key: "id:subject", value: "Hello"),
            .init(key: "name:0:urgent:0", isChecked: true),
            .init(key: "path:body:0/select:2", selectedOptionIndexes: [1, 3])
        ])
    }

    @Test("Rejects malformed reports and skips malformed fields")
    func rejectsMalformed() throws {
        #expect(BrowserFormStateSnapshot(messageBody: "nope") == nil)
        #expect(BrowserFormStateSnapshot(messageBody: ["fields": [] as [Any]] as [String: Any]) == nil)
        let body: [String: Any] = [
            "url": "https://example.com/",
            "fields": [["k": "", "v": "x"], ["v": "no key"], ["k": "id:a"], "junk", ["k": "id:b", "v": "kept"]] as [Any]
        ]
        let snapshot = try #require(BrowserFormStateSnapshot(messageBody: body))
        #expect(snapshot.fields == [.init(key: "id:b", value: "kept")])
    }

    @Test("Caps field count and value length")
    func capsFields() throws {
        let oversized = String(repeating: "x", count: BrowserFormStateSnapshot.maxValueLength + 1)
        var fields: [[String: Any]] = [["k": "id:big", "v": oversized]]
        for index in 0..<(BrowserFormStateSnapshot.maxFieldCount + 10) {
            fields.append(["k": "id:f\(index)", "v": "\(index)"])
        }
        let snapshot = try #require(
            BrowserFormStateSnapshot(messageBody: ["url": "https://example.com/", "fields": fields] as [String: Any])
        )
        #expect(snapshot.fields.count == BrowserFormStateSnapshot.maxFieldCount)
        #expect(snapshot.fields.first?.key == "id:f0")
        #expect(snapshot.hasUnrestorableInput)
    }

    @Test("Input the observer or the caps leave out counts as unrestorable")
    func unrestorableInput() throws {
        let plain = try #require(
            BrowserFormStateSnapshot(messageBody: ["url": "https://example.com/", "fields": [["k": "id:a", "v": "x"]]] as [String: Any])
        )
        #expect(!plain.hasUnrestorableInput)

        let flagged = try #require(
            BrowserFormStateSnapshot(messageBody: ["url": "https://example.com/", "fields": [] as [Any], "unrestorable": true] as [String: Any])
        )
        #expect(flagged.isEmpty)
        #expect(flagged.hasUnrestorableInput)

        let oversized = String(repeating: "x", count: BrowserFormStateSnapshot.maxValueLength + 1)
        let capped = try #require(
            BrowserFormStateSnapshot(messageBody: ["url": "https://example.com/", "fields": [["k": "id:big", "v": oversized]]] as [String: Any])
        )
        #expect(capped.isEmpty)
        #expect(capped.hasUnrestorableInput)
    }

    @Test("Input stays on its origin; file URLs must be the same file")
    func originMatching() {
        let snapshot = BrowserFormStateSnapshot(
            documentURL: URL(string: "https://example.com/a?x=1#top")!,
            fields: [.init(key: "id:a", value: "v")]
        )
        #expect(snapshot.sharesOrigin(with: URL(string: "https://EXAMPLE.com/b")))
        #expect(!snapshot.sharesOrigin(with: URL(string: "https://example.com:8443/a")))
        #expect(!snapshot.sharesOrigin(with: URL(string: "http://example.com/a")))
        #expect(!snapshot.sharesOrigin(with: URL(string: "https://evil.example/a")))
        #expect(!snapshot.sharesOrigin(with: nil))

        let fileSnapshot = BrowserFormStateSnapshot(
            documentURL: URL(fileURLWithPath: "/tmp/a.html"),
            fields: [.init(key: "id:a", value: "v")]
        )
        #expect(fileSnapshot.sharesOrigin(with: URL(string: "file:///tmp/a.html#section")))
        #expect(!fileSnapshot.sharesOrigin(with: URL(fileURLWithPath: "/tmp/b.html")))

        let networkFile = URL(string: "file://server-a/tmp/a.html")!
        let otherNetworkFile = URL(string: "file://server-b/tmp/a.html")!
        let networkFileFragment = URL(string: "file://server-a/tmp/a.html#section")!
        #expect(BrowserFormStateSnapshot.isSameDocument(networkFile, networkFileFragment))
        #expect(!BrowserFormStateSnapshot.isSameDocument(networkFile, otherNetworkFile))
    }

    @Test("Restore payload mirrors the report shape")
    func restorePayload() {
        let snapshot = BrowserFormStateSnapshot(
            documentURL: URL(string: "https://example.com/")!,
            fields: [
                .init(key: "id:a", value: "text"),
                .init(key: "id:b", isChecked: false),
                .init(key: "id:c", selectedOptionIndexes: [2])
            ]
        )
        let payload = snapshot.restorePayload
        #expect(payload.count == 3)
        #expect(payload[0]["k"] as? String == "id:a")
        #expect(payload[0]["v"] as? String == "text")
        #expect(payload[1]["c"] as? Bool == false)
        #expect(payload[2]["s"] as? [Int] == [2])
    }
}
