// SPDX-License-Identifier: GPL-3.0-or-later
@testable import CmuxCuaHelperCore
import Foundation
import os
import Testing

/// The canonical digest against the shared fixtures
/// (schemas/computer-use/approval-fixtures.json, which the Rust lanes read too).
@Suite struct ApprovalCanonicalJSONTests {
    static func fixtures() throws -> [[String: Any]] {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repo.appending(path: "schemas/computer-use/approval-fixtures.json"))
        let file = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(file["cases"] as? [[String: Any]])
    }

    @Test func everyFixtureEncodesToItsCanonicalBytesAndDigest() throws {
        let fixtures = try Self.fixtures()
        #expect(fixtures.count >= 4)
        for fixture in fixtures {
            var request = try #require(fixture["request"] as? [String: Any])
            let canonical = try #require(fixture["canonical"] as? String)
            let digest = try #require(fixture["digest"] as? String)
            #expect(request.removeValue(forKey: "digest") as? String == digest, "the request carries its digest")
            let encoded = try CanonicalJSON.encode(request)
            #expect(String(decoding: encoded, as: UTF8.self) == canonical)
            #expect(CanonicalJSON.sha256Hex(encoded) == digest)
            #expect(CanonicalJSON.sha256Hex(Data(canonical.utf8)) == digest)
        }
    }

    @Test func theTypedRequestHasTheFixtureDigest() throws {
        for fixture in try Self.fixtures() {
            let wire = try #require(fixture["request"] as? [String: Any])
            let target = try #require(wire["target"] as? [String: Any])
            let app = try #require(ApprovalApp(wire: target))
            func string(_ key: String) -> String { wire[key] as? String ?? "" }
            func number(_ key: String) -> Int64 { (wire[key] as? NSNumber)?.int64Value ?? -1 }
            let request = AppApprovalRequest(
                nonce: string("nonce"), client: string("client"), machine: string("machine"),
                session: string("session"), agent: string("agent"), workspace: string("workspace"), target: app,
                tool: string("tool"), risk: string("risk"), createdMs: number("created_ms"),
                waitUntilMs: number("wait_until_ms"), answerableUntilMs: number("answerable_until_ms"))
            #expect(request.digest == fixture["digest"] as? String)
            #expect(String(decoding: request.canonical, as: UTF8.self) == fixture["canonical"] as? String)
        }
    }

    @Test func escapingMatchesSerdeJSON() throws {
        let encoded = try CanonicalJSON.encode(["b": "\"\\/\u{08}\u{0C}\n\r\t\u{01}\u{1F}\u{7F}é🚀", "a": [1, true, NSNull()]])
        #expect(String(decoding: encoded, as: UTF8.self)
            == #"{"a":[1,true,null],"b":"\"\\/\b\f\n\r\t\u0001\u001f"# + "\u{7F}é🚀\"}")
    }

    @Test func fractionsAreRefused() {
        #expect(throws: CanonicalJSON.UnsupportedValue.self) { try CanonicalJSON.encode(["n": 1.5]) }
    }
}

/// `AppApprovalBroker` with a fake host link, a manual clock and manual deadlines.
@Suite struct AppApprovalBrokerTests {
    static let textEdit = ApprovalApp(bundleID: "com.apple.TextEdit", name: "TextEdit")
    static let safari = ApprovalApp(bundleID: "com.apple.Safari", name: "Safari")

    @Test func theQuestionCarriesTheContractFields() async throws {
        let fixture = Fixture()
        fixture.broker.label("s1", SessionLabels(agent: "Claude", workspace: "api-server", client: "ignored"))
        let call = Task { await fixture.broker.ask(session: "s1", app: Self.safari, tool: "click", risk: "R1") }
        let line = try await fixture.host.next()
        #expect(line["type"] as? String == "app_approval")
        let request = try #require(line["request"] as? [String: Any])
        #expect(request["v"] as? Int == 1)
        #expect(request["client"] as? String == "com.cmuxterm.app.debug.cu1")
        #expect(request["machine"] as? String == "mac-1")
        #expect(request["session"] as? String == "s1")
        #expect(request["agent"] as? String == "Claude")
        #expect(request["workspace"] as? String == "api-server")
        #expect(request["tool"] as? String == "click")
        #expect(request["risk"] as? String == "R1")
        let target = try #require(request["target"] as? [String: Any])
        #expect(target["bundle_id"] as? String == "com.apple.Safari")
        #expect(target["executable"] is NSNull)
        #expect(target["name"] as? String == "Safari")
        let created = try #require((request["created_ms"] as? NSNumber)?.int64Value)
        #expect(created == Fixture.start)
        #expect((request["wait_until_ms"] as? NSNumber)?.int64Value == created + 120_000)
        #expect((request["answerable_until_ms"] as? NSNumber)?.int64Value == created + 600_000)
        let nonce = try #require(request["nonce"] as? String)
        #expect(nonce.count == 32 && nonce.allSatisfy(\.isHexDigit))
        var unsigned = request
        let digest = try #require(unsigned.removeValue(forKey: "digest") as? String)
        #expect(CanonicalJSON.sha256Hex(try CanonicalJSON.encode(unsigned)) == digest)
        fixture.answer(line, "deny")
        #expect(await call.value == .decided(.deny))
    }

    @Test func aCallTimesOutAndALateSessionAllowCoversTheRetry() async throws {
        let fixture = Fixture()
        let call = Task { await fixture.broker.ask(session: "s1", app: Self.textEdit, tool: "click", risk: "R1") }
        let line = try await fixture.host.next()
        fixture.scheduler.fire(.seconds(120))
        #expect(await call.value == .timeout)
        #expect(fixture.broker.allowance("s1", Self.textEdit) == .none)
        fixture.clock.advance(by: 300_000)
        fixture.answer(line, "session")
        #expect(fixture.broker.allowance("s1", Self.textEdit) == .granted)
        #expect(fixture.broker.allowedApps("s1") == [Self.textEdit])
        #expect(fixture.broker.allowedApps("s2").isEmpty, "a grant is this session's only")
    }

    @Test func aLateOnceIsOneCallsCredit() async throws {
        let fixture = Fixture()
        let call = Task { await fixture.broker.ask(session: "s1", app: Self.textEdit, tool: "click", risk: "R1") }
        let line = try await fixture.host.next()
        fixture.scheduler.fire(.seconds(120))
        #expect(await call.value == .timeout)
        fixture.answer(line, "once")
        #expect(fixture.broker.allowance("s1", Self.textEdit) == .once)
        #expect(fixture.broker.allowance("s1", Self.textEdit) == .none, "the credit is spent")
        #expect(fixture.broker.allowedApps("s1").isEmpty, "once never joins the manifest")
    }

    @Test func anAnswerAfterTheAnswerableWindowIsIgnored() async throws {
        let fixture = Fixture()
        let call = Task { await fixture.broker.ask(session: "s1", app: Self.textEdit, tool: "click", risk: "R1") }
        let line = try await fixture.host.next()
        fixture.scheduler.fire(.seconds(120))
        #expect(await call.value == .timeout)
        fixture.clock.advance(by: 600_001)
        fixture.answer(line, "always")
        #expect(fixture.broker.allowance("s1", Self.textEdit) == .none)
        // The window's own deadline also closes the question.
        fixture.clock.advance(by: -600_001)
        fixture.scheduler.fire(.seconds(600))
        fixture.answer(line, "always")
        #expect(fixture.broker.allowance("s1", Self.textEdit) == .none)
    }

    @Test func aWrongDigestIsIgnoredAndASecondAnswerToo() async throws {
        let fixture = Fixture()
        let call = Task { await fixture.broker.ask(session: "s1", app: Self.textEdit, tool: "click", risk: "R1") }
        let line = try await fixture.host.next()
        fixture.answer(line, "session", digest: .value(String(repeating: "0", count: 64)))
        fixture.answer(line, "session", digest: .missing)
        fixture.answer(line, "maybe")
        #expect(fixture.broker.allowance("s1", Self.textEdit) == .none, "no valid answer yet")
        fixture.answer(line, "deny")
        #expect(await call.value == .decided(.deny))
        fixture.answer(line, "always")
        #expect(fixture.broker.allowance("s1", Self.textEdit) == .none, "a second answer is ignored")
        #expect(fixture.broker.allowedApps("s1").isEmpty)
    }

    @Test func parallelCallsJoinOneQuestion() async throws {
        let fixture = Fixture()
        let first = Task { await fixture.broker.ask(session: "s1", app: Self.textEdit, tool: "click", risk: "R1") }
        let line = try await fixture.host.next()
        _ = await fixture.scheduler.next() // the first call's wait
        _ = await fixture.scheduler.next() // the question's answerable window
        let second = Task { await fixture.broker.ask(session: "s1", app: Self.textEdit, tool: "type_text", risk: "R1") }
        #expect(await fixture.scheduler.next() == Duration.seconds(120), "the second call joined and waits")
        // Another session asks its own question.
        let other = Task { await fixture.broker.ask(session: "s2", app: Self.textEdit, tool: "click", risk: "R1") }
        let otherLine = try await fixture.host.next()
        #expect((otherLine["request"] as? [String: Any])?["session"] as? String == "s2")
        fixture.answer(line, "session")
        #expect(await first.value == .decided(.session))
        #expect(await second.value == .decided(.session))
        #expect(fixture.host.sent.withLock { $0.count } == 2, "one question per session x app")
        fixture.answer(otherLine, "deny")
        #expect(await other.value == .decided(.deny))
    }

    @Test func onceRunsOneJoinedCallAndTheOthersAskAgain() async throws {
        let fixture = Fixture()
        let first = Task { await fixture.broker.ask(session: "s1", app: Self.textEdit, tool: "click", risk: "R1") }
        let line = try await fixture.host.next()
        _ = await fixture.scheduler.next()
        _ = await fixture.scheduler.next()
        let second = Task { await fixture.broker.ask(session: "s1", app: Self.textEdit, tool: "click", risk: "R1") }
        _ = await fixture.scheduler.next()
        fixture.answer(line, "once")
        #expect(await first.value == .decided(.once), "the asking call runs")
        #expect(await second.value == .retry)
        #expect(fixture.broker.allowance("s1", Self.textEdit) == .none)
    }

    @Test func alwaysSavesTheAppForEverySession() async throws {
        let fixture = Fixture()
        fixture.broker.openSession("s2")
        let call = Task { await fixture.broker.ask(session: "s1", app: Self.textEdit, tool: "click", risk: "R1") }
        fixture.answer(try await fixture.host.next(), "always")
        #expect(await call.value == .decided(.always))
        #expect(fixture.broker.allowance("s2", Self.textEdit) == .granted)
    }

    @Test func approvedAppsReplaceTheSavedListAndRevokeRemovesGrants() async throws {
        let fixture = Fixture()
        fixture.broker.receive(["type": "approved_apps", "apps": [
            ["bundle_id": "com.apple.Safari", "name": "Safari"],
            ["bundle_id": "", "name": "malformed"],
            ["bundle_id": "a", "executable": "/b", "name": "both"],
        ]], link: fixture.link)
        #expect(fixture.broker.allowedApps("s1") == [Self.safari])
        let call = Task { await fixture.broker.ask(session: "s1", app: Self.textEdit, tool: "click", risk: "R1") }
        fixture.answer(try await fixture.host.next(), "session")
        _ = await call.value
        #expect(Set(fixture.broker.allowedApps("s1")) == [Self.safari, Self.textEdit])

        fixture.broker.receive(["type": "revoke", "scope": "app", "app": ["bundle_id": "com.apple.textedit"]],
                               link: fixture.link)
        #expect(fixture.broker.allowedApps("s1") == [Self.safari], "bundle ids compare without case")
        fixture.broker.receive(["type": "approved_apps", "apps": [["bundle_id": "com.apple.TextEdit"]]],
                               link: fixture.link)
        #expect(fixture.broker.allowedApps("s1") == [Self.textEdit], "the list is replaced")
        fixture.broker.receive(["type": "revoke", "scope": "all"], link: fixture.link)
        #expect(fixture.broker.allowedApps("s1").isEmpty)
    }

    @Test func linesFromAnOldLinkAreIgnored() async throws {
        let fixture = Fixture()
        let old = fixture.link
        _ = fixture.broker.attach { _ in }
        fixture.broker.receive(["type": "approved_apps", "apps": [["bundle_id": "com.apple.Safari"]]], link: old)
        #expect(fixture.broker.allowedApps("s1").isEmpty)
    }

    /// The production deadlines (Task.sleep), shortened.
    @Test(.timeLimit(.minutes(1))) func theDefaultDeadlineTimesOut() async throws {
        let host = FakeHost()
        let broker = AppApprovalBroker(client: "c", machine: "m",
                                       timing: .init(wait: .milliseconds(20), answerable: .milliseconds(40)))
        _ = host.attach(to: broker)
        broker.openSession("s1")
        let call = Task { await broker.ask(session: "s1", app: Self.textEdit, tool: "click", risk: "R1") }
        #expect(try await host.next()["type"] as? String == "app_approval")
        #expect(await call.value == .timeout)
    }

    @Test func noCollectorFailsClosed() async throws {
        let broker = AppApprovalBroker(client: "c", machine: "m")
        broker.openSession("s1")
        #expect(await broker.ask(session: "s1", app: Self.textEdit, tool: "click", risk: "R1") == .unavailable)

        let fixture = Fixture()
        let refused = Task { await fixture.broker.ask(session: "s1", app: Self.textEdit, tool: "click", risk: "R1") }
        let line = try await fixture.host.next()
        fixture.broker.receive(["type": "app_approval", "id": line["id"] ?? 0, "ok": false], link: fixture.link)
        #expect(await refused.value == .unavailable)

        let lost = Task { await fixture.broker.ask(session: "s1", app: Self.textEdit, tool: "click", risk: "R1") }
        _ = try await fixture.host.next()
        fixture.broker.detach(fixture.link)
        #expect(await lost.value == .unavailable)
    }

    @Test func endingTheSessionCancelsItsQuestion() async throws {
        let fixture = Fixture()
        let call = Task { await fixture.broker.ask(session: "s1", app: Self.textEdit, tool: "click", risk: "R1") }
        let line = try await fixture.host.next()
        fixture.broker.endSession("s1")
        let cancel = try await fixture.host.next()
        #expect(cancel["type"] as? String == "app_approval_cancel")
        #expect(cancel["id"] as? Int == line["id"] as? Int)
        #expect(await call.value == .ended)
        fixture.answer(line, "session")
        #expect(fixture.broker.allowedApps("s1").isEmpty)
        #expect(await fixture.broker.ask(session: "s1", app: Self.textEdit, tool: "click", risk: "R1") == .ended)
    }

    // MARK: Fakes

    final class Fixture: Sendable {
        static let start: Int64 = 1_793_400_000_000
        let clock = ManualClock(start)
        let scheduler = ManualScheduler()
        let host = FakeHost()
        let broker: AppApprovalBroker
        let link: UInt64

        init() {
            let clock = self.clock
            let scheduler = self.scheduler
            broker = AppApprovalBroker(client: "com.cmuxterm.app.debug.cu1", machine: "mac-1",
                                       now: { clock.now }, schedule: { scheduler.add($0, $1) })
            link = host.attach(to: broker)
            broker.openSession("s1")
            broker.openSession("s2")
        }

        enum Digest { case request, missing, value(String) }

        /// Answers the question `line` asked.
        func answer(_ line: [String: Any], _ decision: String, digest: Digest = .request) {
            let request = line["request"] as? [String: Any] ?? [:]
            var message: [String: Any] = ["type": "app_approval", "id": line["id"] ?? 0, "ok": true,
                                          "decision": decision, "via": "mac"]
            switch digest {
            case .request: message["digest"] = request["digest"]
            case .missing: break
            case .value(let value): message["digest"] = value
            }
            broker.receive(message, link: link)
        }
    }

    final class ManualClock: Sendable {
        private let value: OSAllocatedUnfairLock<Int64>
        init(_ start: Int64) { value = OSAllocatedUnfairLock(initialState: start) }
        var now: Int64 { value.withLock { $0 } }
        func advance(by milliseconds: Int64) { value.withLock { $0 += milliseconds } }
    }

    /// Deadlines fire only when a test fires them.
    final class ManualScheduler: Sendable {
        private let pending = OSAllocatedUnfairLock<[(Duration, @Sendable () -> Void)]>(initialState: [])
        private let added: AsyncStream<Duration>
        private let continuation: AsyncStream<Duration>.Continuation
        // crash-allow: the iterator is used by one test task at a time.
        private nonisolated(unsafe) var iterator: AsyncStream<Duration>.Iterator

        init() {
            (added, continuation) = AsyncStream<Duration>.makeStream()
            iterator = added.makeAsyncIterator()
        }

        func add(_ delay: Duration, _ action: @escaping @Sendable () -> Void) {
            pending.withLock { $0.append((delay, action)) }
            continuation.yield(delay)
        }

        /// The next deadline scheduled.
        func next() async -> Duration? { await iterator.next() }

        func fire(_ delay: Duration) {
            let due = pending.withLock { pending -> [@Sendable () -> Void] in
                let due = pending.filter { $0.0 == delay }.map(\.1)
                pending.removeAll { $0.0 == delay }
                return due
            }
            for action in due { action() }
        }
    }

    /// The host end of the consent link.
    final class FakeHost: Sendable {
        let sent = OSAllocatedUnfairLock<[Data]>(initialState: [])
        private let lines: AsyncStream<Data>
        private let continuation: AsyncStream<Data>.Continuation
        // crash-allow: the iterator is used by one test task at a time.
        private nonisolated(unsafe) var iterator: AsyncStream<Data>.Iterator

        init() {
            (lines, continuation) = AsyncStream<Data>.makeStream()
            iterator = lines.makeAsyncIterator()
        }

        func attach(to broker: AppApprovalBroker) -> UInt64 {
            broker.attach { [self] line in
                sent.withLock { $0.append(line) }
                continuation.yield(line)
            }
        }

        func next() async throws -> [String: Any] {
            let line = try #require(await iterator.next())
            return try #require(HelperWire.object(line.dropLast()))
        }
    }
}
