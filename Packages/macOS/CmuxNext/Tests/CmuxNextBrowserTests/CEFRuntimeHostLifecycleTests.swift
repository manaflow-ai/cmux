import AppKit
@testable import CmuxNextBrowser
import CmuxNextCompat
import Foundation
import Testing

/// p01-process-087: quit, app update and Chromium runtime update with the Chromium Host. Quit asks each page whose
/// beforeunload would ask, one at a time, and the first Stay ends it with every page as it was; quit ends the host and
/// waits for it (bounded) so no host outlives cmux; a newer runtime restarts an idle host on it with every page back
/// and no crash page, and a busy page keeps the host. Against the spy remote shim of CEFRuntimeHostExitTests.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct CEFRuntimeHostLifecycleTests {
    private static let pages = (1...3).map { URL(string: "https://example.com/\($0)")! }

    // MARK: Quit asks the pages

    /// Only the page that would ask asks, after the windows came back; Stay ends the quit, and no later page is asked.
    @Test func stayOnAPageEndsTheQuitAndAsksNoLaterPage() async throws {
        let (runtime, _, wire) = try await Self.startedRuntime()
        defer { wire.close() }
        let tabs = Self.tabs(runtime)
        let shown = Counter()
        let asking: Set<ObjectIdentifier> = [ObjectIdentifier(tabs[1]), ObjectIdentifier(tabs[2])]
        let quit = Task { await runtime.askPagesBeforeQuit(showWindows: { shown.count += 1 }) { asking.contains(ObjectIdentifier($0)) } }

        let question = try await Self.question(on: tabs[1])
        #expect(shown.count == 1, "the windows did not come back before the question")
        #expect(tabs[0].pendingPrompts.isEmpty && tabs[2].pendingPrompts.isEmpty, "more than one page asked at once")
        question.respond(.cancel)

        #expect(await quit.value == .stay)
        #expect(tabs[2].pendingPrompts.isEmpty, "a page asked after the person chose Stay")
        #expect(tabs.allSatisfy { $0.browserID != nil && !$0.isClosed }, "a page closed although the quit ended")
    }

    /// Leave on every asking page lets the quit go on, and says a page asked (the sessions question is not asked again).
    @Test func leaveOnEveryAskingPageLetsTheQuitGoOn() async throws {
        let (runtime, _, wire) = try await Self.startedRuntime()
        defer { wire.close() }
        let tabs = Self.tabs(runtime)
        let asking: Set<ObjectIdentifier> = [ObjectIdentifier(tabs[0]), ObjectIdentifier(tabs[2])]
        let quit = Task { await runtime.askPagesBeforeQuit(showWindows: {}) { asking.contains(ObjectIdentifier($0)) } }

        try await Self.question(on: tabs[0]).respond(.accept)
        try await Self.question(on: tabs[2]).respond(.accept)

        #expect(await quit.value == .leave(asked: true))
    }

    /// With no page that would ask, nothing shows and the windows stay as they are.
    @Test func noAskingPageAsksNothing() async throws {
        let (runtime, _, wire) = try await Self.startedRuntime()
        defer { wire.close() }
        let tabs = Self.tabs(runtime)
        let shown = Counter()

        let answer = await runtime.askPagesBeforeQuit(showWindows: { shown.count += 1 }) { _ in false }

        #expect(answer == .leave(asked: false))
        #expect(shown.count == 0)
        #expect(tabs.allSatisfy { $0.pendingPrompts.isEmpty })
    }

    /// A signal's quit answers the waiting question Leave: it never waits on a page.
    @Test func aSignalAnswersTheWaitingQuestionLeave() async throws {
        let (runtime, _, wire) = try await Self.startedRuntime()
        defer { wire.close() }
        let tabs = Self.tabs(runtime)
        let quit = Task { await runtime.askPagesBeforeQuit(showWindows: {}) { $0 === tabs[1] } }
        _ = try await Self.question(on: tabs[1])

        runtime.answerQuitQuestions(leave: true)

        #expect(await quit.value == .leave(asked: true))
    }

    // MARK: Quit ends the host

    /// Quit's engine stop ends the host and waits for it, within the limit that keeps it inside the quit deadline.
    @Test func quitEndsTheHostWithinTheLimit() async throws {
        let (runtime, supervisor, wire) = try await Self.startedRuntime()
        defer { wire.close() }

        await runtime.shutdown(timeout: .milliseconds(50))

        #expect(supervisor.endLimits == [CEFShutdownSequence.hostEndLimit])
        #expect(runtime.state == .shutDown)
        #expect(HostWire.state.withLock { $0.detaches } >= 1, "quit kept the host's wire open")
    }

    /// A host-mode runtime with no host running at quit (it ended) starts none afterwards.
    @Test func noHostStartsOnceQuitBegan() async throws {
        let (runtime, supervisor, wire) = try await Self.startedRuntime()
        defer { wire.close() }
        runtime.hostEnded(BrowserProcessExit(reason: .killed, code: Int(SIGKILL), engine: .cef))
        #expect(runtime.state == .idle)

        await runtime.shutdown(timeout: .milliseconds(50))

        #expect(runtime.state == .shutDown)
        await #expect(throws: BrowserEngineError.self) { try await runtime.start(layout: nil, environment: [:], trigger: "test") }
        #expect(supervisor.asked == 1, "a host started after quit began")
    }

    // MARK: Runtime update

    /// A newer runtime while every page is hidden and idle: the host ends (cmux's own end, no crash), the next one starts,
    /// and every page comes back on it when shown, without a crash page.
    @Test func aRuntimeUpdateRestartsAnIdleHostWithEveryPageAndNoCrashPage() async throws {
        let (runtime, supervisor, wire) = try await Self.startedRuntime()
        defer { wire.close() }
        let tabs = Self.tabs(runtime)
        let update = try #require(runtime.hostStart?.runtimeUpdate)
        update.pageBlocker = { _ in nil }

        supervisor.newerRuntime()
        for _ in 0..<1_000 where supervisor.asked < 2 { await Task.yield() }
        // Joins the restart's attach, so the test resumes once the runtime is ready again.
        try await runtime.start(layout: nil, environment: [:], trigger: "test")
        let restores = try #require(runtime.hostStart?.pageRestores)
        for _ in 0..<1_000 where tabs.contains(where: { restores.phase(of: $0) != .waitsForShow }) { await Task.yield() }

        #expect(supervisor.endLimits == [CEFShutdownSequence.hostEndLimit], "the old host was not ended before the next one")
        #expect(supervisor.asked == 2, "no host started on the newer runtime")
        #expect(tabs.allSatisfy { $0.state.processExit == nil }, "a page showed a crash page for a planned restart")
        #expect(runtime.crashLog.records.isEmpty, "a planned restart was logged as a crash")
        #expect(tabs.allSatisfy { restores.phase(of: $0) == .waitsForShow }, "a hidden page does not come back when shown")
        #expect(tabs.map(\.pendingURL) == Self.pages)
        #expect(update.phase == .none && update.restarts == 1)
        #expect(HostWire.state.withLock { $0.deadWireOps } == 0, "an op went to the old host's wire")
    }

    /// A page playing audio keeps the host; once it stops, the next check restarts it.
    @Test func aPagePlayingAudioKeepsTheHostUntilItStops() async throws {
        let (runtime, supervisor, wire) = try await Self.startedRuntime()
        defer { wire.close() }
        let tabs = Self.tabs(runtime)
        let update = try #require(runtime.hostStart?.runtimeUpdate)
        update.pageBlocker = { _ in nil }
        tabs[1].isAudible = true

        supervisor.newerRuntime()
        for _ in 0..<1_000 where update.phase == .waiting(blocker: nil) { await Task.yield() }

        #expect(update.phase == .waiting(blocker: "a page plays audio"))
        #expect(update.retry != nil, "a kept host is never checked again")
        #expect(supervisor.endLimits.isEmpty && runtime.state == .ready, "the host restarted under a playing page")

        tabs[1].isAudible = false
        runtime.checkHostRuntimeUpdate()
        for _ in 0..<1_000 where supervisor.asked < 2 { await Task.yield() }
        try await runtime.start(layout: nil, environment: [:], trigger: "test")
        #expect(supervisor.endLimits.count == 1)
    }

    /// What a page says of itself (form input, a beforeunload handler) keeps the host too.
    @Test func aPageWithFormInputKeepsTheHost() async throws {
        let (runtime, supervisor, wire) = try await Self.startedRuntime()
        defer { wire.close() }
        let tabs = Self.tabs(runtime)
        let update = try #require(runtime.hostStart?.runtimeUpdate)
        update.pageBlocker = { $0 === tabs[2] ? "a page has form input" : nil }

        supervisor.newerRuntime()
        for _ in 0..<1_000 where update.phase == .waiting(blocker: nil) { await Task.yield() }

        #expect(update.phase == .waiting(blocker: "a page has form input"))
        #expect(supervisor.endLimits.isEmpty && runtime.state == .ready)
    }

    // MARK: Fixtures

    /// The question `tab` shows, once it does.
    private static func question(on tab: CEFTab) async throws -> BrowserPrompt {
        for _ in 0..<1_000 where !tab.pendingPrompts.contains(where: { $0.kind.isBeforeUnload }) { await Task.yield() }
        return try #require(tab.pendingPrompts.first { $0.kind.isBeforeUnload }, "the page did not ask")
    }

    /// Three hidden tabs at ``pages``, browsers 1 to 3, each in a pane of its own.
    private static func tabs(_ runtime: CEFRuntime) -> [CEFTab] {
        pages.enumerated().map { index, url in
            let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
            host.endOfTurn = { $0() }
            let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(tab)
            runtime.register(tab, browser: Int32(index + 1))
            tab.committedURL = url
            return tab
        }
    }

    /// A runtime started in host mode over the spy remote shim. It outlives the test: a pane's scheduled work reads it
    /// through an unowned reference.
    private static func startedRuntime() async throws -> (CEFRuntime, LifecycleHost, HostWire.Pipe) {
        HostWire.reset()
        let wire = try HostWire.Pipe()
        let supervisor = LifecycleHost(controlFD: wire.fd)
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-host-lifecycle-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(storage: CEFProfileStorage(root: root))
        runtime.loadInProcess = { _ in .failure(.notEmbedded) }
        runtime.adoptHost(supervisor)
        runtime.hostStart = CEFHostStart(supervisor: supervisor, open: { _ in
            do throws(CEFShimLibrary.LoadError) { return .success(try CEFRemoteShim.make(symbol: HostWire.symbol, expected: HostWire.abi)) } catch { return .failure(.shim(error)) }
        })
        try await runtime.start(layout: nil, environment: [:], trigger: "test")
        _ = Unmanaged.passRetained(runtime)
        return (runtime, supervisor, wire)
    }
}

/// Hands out the spy's wire on each request, records each end cmux asks for (and returns at once, as a host that ended
/// in time), and tells the runtime of a newer runtime (``newerRuntime()``).
@MainActor private final class LifecycleHost: @MainActor ChromiumHostExitReporting {
    var onHostEnded: (@MainActor (BrowserProcessExit) -> Void)?
    var savedNavigation: ChromiumHostSavedNavigation?
    private(set) var asked = 0
    /// Each ``endHost(within:)`` call's limit.
    private(set) var endLimits: [Duration] = []
    private var runtimeObservers: [@MainActor () -> Void] = []
    private let controlFD: Int32

    init(controlFD: Int32) {
        self.controlFD = controlFD
    }

    func attachment() async throws(ChromiumHostAttachError) -> ChromiumHostAttachment {
        asked += 1
        return ChromiumHostAttachment(controlFD: controlFD, remoteShim: URL(filePath: "/nonexistent/libcmux_cef_shim_remote.dylib"),
                                      frameworkLocales: ["en.lproj"])
    }

    func observeHostEnds(_ ended: @escaping @MainActor () -> Void) {}

    func endHost(within limit: Duration) async {
        endLimits.append(limit)
    }

    func observeRuntimeChanges(_ changed: @escaping @MainActor () -> Void) {
        runtimeObservers.append(changed)
    }

    func newerRuntime() {
        runtimeObservers.forEach { $0() }
    }
}

@MainActor private final class Counter {
    var count = 0
}
