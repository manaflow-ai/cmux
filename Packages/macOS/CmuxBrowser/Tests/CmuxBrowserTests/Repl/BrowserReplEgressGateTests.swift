import Foundation
import Testing

@testable import CmuxBrowser

/// What leaves the native side for a session's JavaScript passes one egress
/// gate (``BrowserReplBoundary/egress(_:)``) that masks every held value in
/// the original data, and page URLs reach a session that did not create
/// their tab without their credential values (``BrowserReplPageURL``).
@Suite("Browser REPL egress gate", .serialized)
struct BrowserReplEgressGateTests {
    private static let value = "v4lue-xyz-7731"
    private static let protected = "s3cr3t-value-0042"
    private static let suffix = "-value-0042"

    private func spelled(_ text: String) -> String {
        text.map(String.init).joined(separator: " ")
    }

    @Test("A file name holding a secret reaches JavaScript masked in every fs answer")
    func fileNamesAreMasked() async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-repl-egress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        // A page's download keeps the name the page gave it.
        try Data("report".utf8).write(to: work.appendingPathComponent("report-\(Self.value).txt"))
        let bundle = try browserReplRepositoryBundle()
        let session = BrowserReplSession(id: "egress-\(UUID().uuidString)", cwd: work.path, bundle: bundle, driver: ScriptedPageDriver())
        defer { session.close() }
        let result = await browserReplWithDeadline(seconds: 60) {
            await session.evaluate(code: """
            const fs = await import("node:fs");
            secrets.set("k", "\(Self.value)", { domains: ["example.com"] });
            const names = fs.readdirSync(".");
            console.log("names", names.join(",").split("").join(" "));
            console.log("masked", names.some((name) => name.includes("<secret:k>")));
            """, timeout: .seconds(30))
        }
        let output = result?.lines.map(\.text).joined(separator: "\n") ?? ""
        #expect(result?.error == nil, "\(result?.error ?? "")")
        #expect(!output.contains(spelled(Self.value)), "\(output)")
        #expect(output.contains("masked true"), "\(output)")
    }

    /// The decision note: the driver masked the values other sessions typed
    /// before the session's own pass, so a typed value overlapping the start
    /// of the session's secret replaced that start first, and the session's
    /// pass no longer found its secret: the rest of it leaked.
    @Test("A value another session typed never unmasks the rest of the session's own secret")
    func typedValueMaskedFirstDoesNotUnmaskOwnSecret() throws {
        let typed = BrowserReplSecretStore()
        try typed.setLiteral(key: "typed-1", maskName: "password", value: "Xs3cr3t", domains: [])
        let boundary = BrowserReplBoundary(typedSecrets: { typed })
        try boundary.secrets.set(name: "key", value: Self.protected, domains: ["example.com"], totp: false, title: "t")
        // What the driver hands the session now: its output, unmasked.
        let output = BrowserReplDriverOutput(reader: "me")

        let driverResult: Result<String, BrowserReplDriverError> = .success(output.result(["text": "Xs3cr3t-value-0042"]) ?? "null")
        let result = boundary.egress(.driverResult(method: "frame.evaluate", driverResult)).text
        #expect(!result.contains(Self.suffix), "\(result)")
        #expect(result.contains("<secret:"), "\(result)")

        let driverError: Result<String, BrowserReplDriverError> = .failure(BrowserReplDriverError(code: "invalid", message: "saw Xs3cr3t-value-0042"))
        let error = boundary.egress(.driverResult(method: "frame.evaluate", driverError)).text
        #expect(!error.contains(Self.suffix), "\(error)")

        let event = output.event(["targetId": "T", "text": "Xs3cr3t-value-0042"]) ?? "{}"
        let delivered = boundary.egress(.event(name: "console", payloadJSON: event, maxBytes: 1 << 20)).text
        #expect(!delivered.contains(Self.suffix), "\(delivered)")
    }

    static let signed = "https://user:hunter2@app.example/callback?code=c0de&state=s"

    /// The navigation guard tells every attached session of a navigation
    /// it cancelled; a session that did not create the tab must not read
    /// the URL's credentials from it.
    @Test("A cancelled navigation's URL reaches a session that did not create the tab without its credentials")
    func blockedNavigationURLIsStrippedForOtherSessions() throws {
        let payload: [String: Any] = ["targetId": "T", "url": Self.signed, "reason": "not in session.allowedDomains (docs.example)"]
        let seen = JSONSerialization.browserReplObject(BrowserReplDriverOutput(reader: "other").event(payload) ?? "{}")
        let url = try #require(seen["url"] as? String)
        #expect(!url.contains("hunter2") && !url.contains("c0de"), "\(url)")
        #expect(url.contains("app.example/callback") && url.contains("state=s"), "\(url)")
    }

    /// A popup's first URL is the page's choice, as a cancelled one is.
    @Test("A popup's URL reaches a session that did not create the tab without its credentials")
    func popupURLIsStrippedForOtherSessions() throws {
        let payload: [String: Any] = ["targetId": "P", "openerTargetId": "T", "url": Self.signed, "userOwned": true]
        let seen = JSONSerialization.browserReplObject(BrowserReplDriverOutput(reader: "other").event(payload) ?? "{}")
        let url = try #require(seen["url"] as? String)
        #expect(!url.contains("hunter2") && !url.contains("c0de"), "\(url)")
    }

    @Test("The tab's live creator reads a page URL as written, and the reason that repeats it too")
    func creatorReadsTheURLAsWritten() throws {
        let payload: [String: Any] = [
            "targetId": "T",
            "url": BrowserReplPageURL(Self.signed, creator: "creator"),
            "reason": "\(Self.signed) is blocked",
        ]
        let creator = JSONSerialization.browserReplObject(BrowserReplDriverOutput(reader: "creator").event(payload) ?? "{}")
        #expect(creator["url"] as? String == Self.signed)
        #expect(creator["reason"] as? String == "\(Self.signed) is blocked")
        let other = JSONSerialization.browserReplObject(BrowserReplDriverOutput(reader: "other").event(payload) ?? "{}")
        let reason = try #require(other["reason"] as? String)
        #expect(!reason.contains("hunter2") && !reason.contains("c0de"), "\(reason)")
    }
}
