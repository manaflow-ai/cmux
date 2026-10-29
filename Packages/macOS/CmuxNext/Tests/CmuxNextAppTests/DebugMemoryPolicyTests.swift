import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
@testable import CmuxNextControl
import CmuxNextHibernation
import CmuxNextMemory
import CmuxNextRemote
import CmuxNextSettings
import CmuxNextWakeups
import Darwin
import Foundation
import Testing

/// The socket and relay policy of the memory diagnostics: `debug.memory` and
/// `debug.discards` are read-only automation-class main-actor copies whose parse and encode run off
/// the main actor; no relay may forward them or the daemon's `memory-report`; only the local owner
/// gets an answer; and a release router serves both with no URL, title or path in the answer
/// (skills/cmux-socket-policy/references/remote-relay-authorization.md). The daemon's half is
/// `cargo test -p cmux-tui-core memory_report`.
@MainActor @Suite(.serialized) struct DebugMemoryPolicyTests {
    @MainActor final class Executor: ControlActionExecutor {
        func performAction(_ request: ControlActionRequest) -> ControlActionOutcome { .ran }
    }

    /// The threads a closure ran on (true: main).
    nonisolated final class Threads: Sendable {
        private let lock = Mutex<[Bool]>([])
        func note() { lock.withLock { $0.append(Thread.isMainThread) } }
        var onMain: [Bool] { lock.withLock { $0 } }
    }

    static let memoryNames = ["debug.memory", "debug.discards", "memory-report"]
    static let secrets = ["example.com", "https", "/Users", "someone", "Quarterly", "secret"]

    private static func emptySnapshot() -> MemoryDiagnosticsSnapshot {
        MemoryDiagnosticsSnapshot(
            report: MemoryReport(level: .normal, mode: .medium,
                                 budget: .forMemory(physicalBytes: 16 << 30, gpuResidentAvailable: false), consumers: []),
            kernelLevel: .normal, override: nil, history: .init(changes: [], levelSinceMilliseconds: 0),
            tabs: [.init(key: "https://example.com/secret?q=1", kind: .browser, engine: .webkit, state: .live, visible: false)],
            workspaces: [.init(id: "/Users/someone/project", state: .mounted, panes: 1)],
            terminal: .init(warmCapacity: 8, surfaces: 0, rendering: 0, hiddenNonvolatileIOSurfaceBytes: nil, lastFrames: 0),
            spares: [])
    }

    /// Owner reports whose keys carry a URL, a path and a title, and one plain tab key.
    private static func leakyDiscards() -> ContentDiscardReport {
        var report = ContentDiscardReport(tracking: .browser, .agentPage)
        let now = ContinuousClock.now
        report.note(.hidden("https://example.com/secret?q=1", .browser), at: now)
        report.note(.hidden("/Users/someone/secret.html", .browser), at: now)
        report.note(.shown("Quarterly Report - Draft", .agentPage), at: now)
        report.note(.hidden("tab-plain", .browser), at: now)
        return report
    }

    private func methods(threads: Threads = Threads(),
                         discards: @escaping @MainActor @Sendable () -> ContentDiscardReport = { DebugMemoryPolicyTests.leakyDiscards() }) -> [ControlMethod] {
        [
            DebugMemoryControl.memoryMethod(read: { threads.note(); return Self.emptySnapshot() },
                                            sample: { _ in threads.note(); return MemoryDiagnosticsProcesses(rows: []) }),
            DebugHibernationControl.discardsMethod(read: { threads.note(); return discards() },
                                                now: { threads.note(); return .now }),
        ]
    }

    private func router(allowsDebug: Bool, threads: Threads = Threads()) -> ControlRouter {
        let router = ControlRouter(identity: ControlIdentity(version: "1.0", build: "1", bundleID: "com.cmuxterm.app.debug.test",
                                                             tag: "test", processID: getpid()),
                                   executor: Executor(),
                                   configuration: .init(requestDeadline: .seconds(30), allowsDebugMethods: allowsDebug))
        router.register(methods(threads: threads))
        return router
    }

    // MARK: Socket policy

    /// Both methods are read-only main-actor copies in the automation class (after the person's
    /// input, never `injectingInput()`), marked for release builds; the read is the only main-actor
    /// work: the processes are sampled, `kind` is parsed and both answers are encoded off it.
    @Test func bothAreAutomationClassCopiesParsedAndEncodedOffMain() async throws {
        for method in methods() {
            #expect(method.lane == .mainActor, "\(method.name)")
            #expect(method.workClass == .automation, "\(method.name) runs ahead of the person's input")
            #expect(method.servesRelease, "\(method.name)")
        }
        let threads = Threads()
        let router = router(allowsDebug: true, threads: threads)
        _ = try await router.handle(ControlRequest(id: "1", method: "debug.memory")).get()
        _ = try await router.handle(ControlRequest(id: "2", method: "debug.discards", params: ["kind": "browser"])).get()
        #expect(threads.onMain == [true, false, true, false], "read on main, sample and parse off it")
    }

    /// A bad `kind` (a name that is no content kind, or not a string) is a typed `invalid_params`
    /// error, not an answer; a real kind keeps that kind's one row, and a null kind keeps all nine.
    @Test func aBadKindIsInvalidParams() async throws {
        let router = router(allowsDebug: false)
        for bad: JSONValue in ["tab", "sidebar", 3, true] {
            #expect(ContentKind(rawValue: bad.stringValue ?? "") == nil, "\(bad) must not be a content kind")
            let reply = await router.handle(ControlRequest(id: "1", method: "debug.discards", params: ["kind": bad]))
            #expect(throws: ControlError.self) { try reply.get() }
            if case .failure(let error) = reply { #expect(error.code == "invalid_params", "\(bad)") }
        }
        let one = try await router.handle(ControlRequest(id: "2", method: "debug.discards", params: ["kind": "sidebar_section"])).get()
        let rows = one.objectValue?["kinds"]?.arrayValue ?? []
        #expect(rows.count == 1)
        #expect(rows.first?.objectValue?["kind"] == .string(ContentKind.sidebarSection.rawValue))
        let all = try await router.handle(ControlRequest(id: "3", method: "debug.discards", params: ["kind": .null])).get()
        #expect(all.objectValue?["kinds"]?.arrayValue?.count == ContentKind.allCases.count)
    }

    // MARK: Relay

    /// No relay forwards a memory diagnostic under any name: not on the default (empty) allowlist,
    /// and dropped from any allowlist that names one. The policy still allows a listed read on an
    /// owned target, so the denial is the method's, not an empty policy's.
    @Test func noRelayForwardsAMemoryDiagnostic() {
        for method in Self.memoryNames + ["memory.limit", "app.memory", "tabs.discards"] {
            #expect(RemoteRelayPolicy.denyAll.decide(method: method, params: [:], owned: .init()) == .deny(.notAllowlisted(method)))
            let listed = RemoteRelayPolicy(allowed: [method])
            #expect(listed.allowed.isEmpty, "\(method) stays on a relay allowlist")
            #expect(listed.decide(method: method, params: [:], owned: .init()) == .deny(.notAllowlisted(method)))
        }
        let reads = RemoteRelayPolicy(allowed: ["workspace.list"])
        #expect(reads.decide(method: "workspace.list", params: [:], owned: .init()) == .allow)
    }

    // MARK: Local owner

    /// The control socket answers the memory diagnostics only to the local owner: a same-uid peer in
    /// automation mode gets the answer; another uid, an unknown uid and a socket that is off are
    /// refused before the router reads anything.
    @Test func onlyTheLocalOwnerGetsAnAnswer() async throws {
        let threads = Threads()
        let router = router(allowsDebug: false, threads: threads)
        func respond(_ mode: ControlAccessMode, uid: uid_t?, method: String) async -> String? {
            var authorizer = ControlAuthorizer(configuration: .init(path: "/nonexistent/cmux-policy.sock", accessMode: mode),
                                               peer: .init(pid: getpid(), uid: uid))
            return await authorizer.respond(to: #"{"id":1,"method":"\#(method)"}"#, router: router).0
        }
        for method in ["debug.memory", "debug.discards"] {
            let owner = try #require(await respond(.automation, uid: getuid(), method: method))
            let reply = try #require(try JSONValue.parse(Data(owner.utf8)).objectValue)
            #expect(reply["ok"] == .bool(true), "\(method): \(owner)")
            #expect(await respond(.automation, uid: getuid() &+ 1, method: method) == ControlAuthorizer.accessDenied)
            #expect(await respond(.automation, uid: nil, method: method) == ControlAuthorizer.accessDenied)
            #expect(await respond(.off, uid: getuid(), method: method) == ControlAuthorizer.accessDenied)
        }
        #expect(threads.onMain.count == 4, "only the owner's two requests read and encoded: \(threads.onMain)")
    }

    // MARK: Release redaction

    /// A release router serves both (and drops other debug methods); neither answer holds a URL,
    /// title or path even when a tab key, a workspace ID or a content key carries one, and a plain
    /// tab key is kept.
    @Test func releaseServesBothWithNoURLTitleOrPath() async throws {
        let release = router(allowsDebug: false)
        release.register([.async("debug.other") { _ in .null }])
        #expect(release.method(named: "debug.memory")?.servesRelease == true)
        #expect(release.method(named: "debug.discards")?.servesRelease == true)
        #expect(release.method(named: "debug.other") == nil)

        for method in ["debug.memory", "debug.discards"] {
            let reply = try await release.handle(ControlRequest(id: "1", method: method)).get()
            let text = reply.compactText
            for secret in Self.secrets {
                #expect(!text.contains(secret), "\(method): \(secret) leaked: \(text)")
            }
        }
        let discards = try await release.handle(ControlRequest(id: "2", method: "debug.discards")).get()
        let keys = discards.objectValue?["contents"]?.arrayValue?.compactMap { $0.objectValue?["key"]?.stringValue } ?? []
        #expect(keys.sorted() == [MemoryDiagnosticsReport.redacted, MemoryDiagnosticsReport.redacted, MemoryDiagnosticsReport.redacted,
                                  "tab-plain"].sorted())
        #expect(MemoryDiagnosticsReport.opaqueToken("tab-plain") == "tab-plain")
        #expect(MemoryDiagnosticsReport.opaqueToken("file:///Users/someone") == MemoryDiagnosticsReport.redacted)
    }
}
