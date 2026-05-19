import XCTest
@testable import CMUXAgentLaunch

final class GrokSessionSummaryReaderTests: XCTestCase {
    func testSummaryUsesMatchingCWDOnlyWhenCWDIsProvided() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-grok-summary-\(UUID().uuidString)", isDirectory: true)
        let grokHome = root.appendingPathComponent(".grok", isDirectory: true)
        let matchingCWD = root.appendingPathComponent("matching", isDirectory: true)
        let otherCWD = root.appendingPathComponent("other", isDirectory: true)
        let sessionId = "019e2e3c-5aac-7012-a9cc-5284c9aa94ce"

        defer { try? FileManager.default.removeItem(at: root) }

        try writeSession(
            grokHome: grokHome,
            cwd: otherCWD.path,
            sessionId: sessionId,
            title: "Wrong project",
            assistantMessage: "This must not be used."
        )

        let reader = GrokSessionSummaryReader(grokHome: grokHome)
        XCTAssertNil(reader.summary(sessionId: sessionId, cwd: matchingCWD.path))

        try writeSession(
            grokHome: grokHome,
            cwd: matchingCWD.path,
            sessionId: sessionId,
            title: "Right project",
            assistantMessage: "Use the cwd-scoped session."
        )

        let summary = try XCTUnwrap(reader.summary(sessionId: sessionId, cwd: matchingCWD.path))
        XCTAssertEqual(summary.title, "Right project")
        XCTAssertEqual(summary.lastAssistantMessage, "Use the cwd-scoped session.")
    }

    func testLatestSummaryDoesNotFallBackGloballyWhenCWDIsProvided() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-grok-latest-\(UUID().uuidString)", isDirectory: true)
        let grokHome = root.appendingPathComponent(".grok", isDirectory: true)
        let requestedCWD = root.appendingPathComponent("requested", isDirectory: true)
        let otherCWD = root.appendingPathComponent("other", isDirectory: true)

        defer { try? FileManager.default.removeItem(at: root) }

        try writeSession(
            grokHome: grokHome,
            cwd: otherCWD.path,
            sessionId: "other-session",
            title: "Other project",
            assistantMessage: "This message belongs to another project."
        )

        let reader = GrokSessionSummaryReader(grokHome: grokHome)
        XCTAssertNil(reader.latestSummary(cwd: requestedCWD.path))
        XCTAssertEqual(reader.latestSummary(cwd: nil)?.lastAssistantMessage, "This message belongs to another project.")
    }

    func testAssistantTextReadsLatestTextBlockMessage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-grok-blocks-\(UUID().uuidString)", isDirectory: true)
        let grokHome = root.appendingPathComponent(".grok", isDirectory: true)
        let cwd = root.appendingPathComponent("blocks", isDirectory: true)
        let sessionId = "blocks-session"

        defer { try? FileManager.default.removeItem(at: root) }

        let sessionDirectory = try makeSessionDirectory(
            grokHome: grokHome,
            cwd: cwd.path,
            sessionId: sessionId
        )
        try #"{"generated_title":"Blocks"}"#
            .write(to: sessionDirectory.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
        try """
        {"type":"assistant","content":[{"type":"text","text":"First message"}]}
        {"type":"assistant","content":[{"type":"text","text":"Latest"},{"type":"text","text":"answer"}]}
        """
        .write(to: sessionDirectory.appendingPathComponent("chat_history.jsonl"), atomically: true, encoding: .utf8)

        let summary = try XCTUnwrap(GrokSessionSummaryReader(grokHome: grokHome).summary(sessionId: sessionId, cwd: cwd.path))
        XCTAssertEqual(summary.title, "Blocks")
        XCTAssertEqual(summary.lastAssistantMessage, "Latest answer")
    }

    private func writeSession(
        grokHome: URL,
        cwd: String,
        sessionId: String,
        title: String,
        assistantMessage: String
    ) throws {
        let sessionDirectory = try makeSessionDirectory(grokHome: grokHome, cwd: cwd, sessionId: sessionId)
        try #"{"session_summary":"\#(title)"}"#
            .write(to: sessionDirectory.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
        try #"{"type":"assistant","content":"\#(assistantMessage)"}"#
            .write(to: sessionDirectory.appendingPathComponent("chat_history.jsonl"), atomically: true, encoding: .utf8)
    }

    private func makeSessionDirectory(
        grokHome: URL,
        cwd: String,
        sessionId: String
    ) throws -> URL {
        let sessionDirectory = grokHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(GrokSessionSummaryReader.encodedSessionCWD(cwd), isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        return sessionDirectory
    }
}
