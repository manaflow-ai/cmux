@testable import CmuxNextBrowser
import Foundation
import Testing

/// The Mail.app source (DESIGN.md "Email sources"): one `osascript` JXA run per read, which never
/// launches Mail, asks only for messages since the wait started, and returns the From address
/// (never the display name) and the DKIM result aligned with the From domain.
@Suite struct MailAppVerificationSourceTests {
    /// Records the command and returns canned output.
    actor FakeRunner: VerificationScriptRunning {
        let output: Result<String, any Error>
        private(set) var calls: [[String]] = []
        init(_ output: Result<String, any Error>) { self.output = output }
        func run(_ arguments: [String]) async throws -> String {
            calls.append(arguments)
            return try output.get()
        }
    }

    static let since = Date(timeIntervalSince1970: 1_800_000_000)

    static func json(_ messages: [[String: Any]]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: messages), as: UTF8.self) // swiftlint:disable:this force_try
    }

    static let github: [String: Any] = [
        "id": "<abc@github.com>",
        "sender": "GitHub <noreply@github.com>",
        "subject": "[GitHub] Please verify your device",
        "content": "Verification code: 482913",
        "received": 1_800_000_030_000.0,
        "headers": "Authentication-Results: mx.example.net;\n dkim=pass header.d=github.com header.s=pf2023;\n spf=pass\nFrom: GitHub <noreply@github.com>\n",
    ]

    @Test func readsMessagesSinceTheWaitStarted() async throws {
        let runner = FakeRunner(.success(Self.json([Self.github])))
        let emails = try await MailAppVerificationSource(runner: runner).emails(receivedSince: Self.since)
        let email = try #require(emails.first)
        #expect(emails.count == 1)
        #expect(email.id == "mail:<abc@github.com>")
        #expect(email.senderAddress == "noreply@github.com")
        #expect(email.senderAuthenticated == true)
        #expect(email.body == "Verification code: 482913")
        #expect(email.receivedAt == Date(timeIntervalSince1970: 1_800_000_030))
        let call = try #require(await runner.calls.first)
        #expect(call.first == "-l" && call.dropFirst().first == "JavaScript")
        #expect(call.last == "1800000000000")
    }

    @Test(arguments: [
        ("dkim=pass header.d=github.com", true),
        ("dkim=pass header.d=mail.github.com", true),
        ("dkim=pass header.d=evil.com", nil as Bool?),
        ("dkim=fail header.d=github.com", false),
        ("dmarc=fail header.from=github.com", false),
        ("spf=pass", nil),
    ] as [(String, Bool?)])
    func readsTheAlignedDKIMResult(results: String, expected: Bool?) async throws {
        var message = Self.github
        message["headers"] = "Authentication-Results: mx.example.net; \(results)\n"
        let runner = FakeRunner(.success(Self.json([message])))
        let email = try #require(try await MailAppVerificationSource(runner: runner).emails(receivedSince: Self.since).first)
        #expect(email.senderAuthenticated == expected)
    }

    @Test func aBareAddressSenderIsRead() async throws {
        var message = Self.github
        message["sender"] = "noreply@github.com"
        let runner = FakeRunner(.success(Self.json([message])))
        #expect(try await MailAppVerificationSource(runner: runner).emails(receivedSince: Self.since).first?.senderAddress == "noreply@github.com")
    }

    @Test func malformedRowsAreSkipped() async throws {
        let runner = FakeRunner(.success(Self.json([["id": "x"], Self.github])))
        #expect(try await MailAppVerificationSource(runner: runner).emails(receivedSince: Self.since).count == 1)
    }

    @Test func nothingWhenMailIsNotRunning() async throws {
        let runner = FakeRunner(.success("[]"))
        #expect(try await MailAppVerificationSource(runner: runner).emails(receivedSince: Self.since).isEmpty)
    }

    @Test func aDeniedAutomationPermissionIsAnError() async {
        let runner = FakeRunner(.failure(VerificationScriptFailure(status: 1, message: "Not authorized to send Apple events to Mail. (-1743)")))
        await #expect(throws: MailAppVerificationSource.Failure.notAuthorized) {
            try await MailAppVerificationSource(runner: runner).emails(receivedSince: Self.since)
        }
    }
}
