@testable import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextSignposts
@testable import CmuxNextTrace
import Foundation
import Testing

/// `cef.create_browser` (p09-observability 033): every shim create (`cmux_shim_create_window`,
/// `cmux_shim_create_placeholder_window`) is inside one async pair, role-aware. In process the pair is the create
/// call; in host mode it stays open until the host's created reply for its window request (a late one, or one
/// that comes during quit, included), or until quit stops waiting for it.
/// The begin's `arg0` holds the spare bit and the profile index. Against a spy shim; each test has its own
/// runtime and trace runtime.
@MainActor @Suite(.serialized) struct CEFPaneHostTests {
    private static let name = SignpostName.cefCreateBrowser.rawValue

    @Test func anInProcessCreateIsOnePairThatEndsWhenTheCallReturns() throws {
        let (runtime, root, log) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = Self.paneHost(runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        host.ensureCreated(tab)
        #expect(CreateSpy.windowCreates == 1)
        let records = log.records(named: Self.name)
        #expect(records.map(\.phase) == [.asyncBegin, .asyncEnd], "the pair closes before Chromium's reply")
        #expect(records.first?.arg1 == records.last?.arg1)
        #expect(records.first?.arg0 == CEFCreateBrowserTrace.beginArg0(spare: false, profileIndex: 0))

        try Self.comeUp(runtime, browser: 10)
        #expect(log.records(named: Self.name).count == 2, "the created reply writes nothing in process")
        #expect(runtime.spareWindow.createTrace.openCount == 0)
    }

    @Test func aSparesCreateCarriesTheSpareBit() throws {
        let (runtime, root, log) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(runtime.spareWindow.prepare(.browser, runtime: runtime))
        let begin = try #require(log.records(named: Self.name).first)
        #expect(begin.phase == .asyncBegin)
        #expect(begin.arg0 == CEFCreateBrowserTrace.beginArg0(spare: true, profileIndex: 0))
    }

    @Test func aHostModeCreateEndsAtTheHostsCreatedReply() throws {
        let (runtime, root, log) = try Self.spyRuntime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = Self.paneHost(runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        host.ensureCreated(tab)
        #expect(log.records(named: Self.name).map(\.phase) == [.asyncBegin], "sent is not created")
        #expect(runtime.spareWindow.createTrace.openCount == 1)

        try Self.comeUp(runtime, browser: 10)
        let records = log.records(named: Self.name)
        #expect(records.map(\.phase) == [.asyncBegin, .asyncEnd])
        #expect(records.first?.arg1 == records.last?.arg1)
        #expect(runtime.spareWindow.createTrace.openCount == 0)
    }

    @Test func aLateReplyForATabThatClosedStillEndsItsPair() throws {
        let (runtime, root, log) = try Self.spyRuntime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = Self.paneHost(runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        host.ensureCreated(tab)
        host.removed(tab)
        try Self.comeUp(runtime, browser: 10)
        #expect(CreateSpy.closed == [10], "the late browser closes")
        #expect(log.records(named: Self.name).map(\.phase) == [.asyncBegin, .asyncEnd])
        #expect(runtime.spareWindow.createTrace.openCount == 0)
    }

    @Test func aHostModeReplyThatComesDuringQuitStillEndsItsPair() async throws {
        let (runtime, root, log) = try Self.spyRuntime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = Self.paneHost(runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        host.ensureCreated(tab)
        let request = try #require(runtime.pendingWindows.keys.first)

        let quit = Task { await runtime.shutdown(timeout: .seconds(2)) }
        for _ in 0..<100 where runtime.shutdownSequence == nil { await Task.yield() }
        #expect(runtime.shutdownSequence != nil, "quit began")
        runtime.handle(.afterCreated(browser: 10, request: request, window: 10))
        #expect(CreateSpy.closed == [10], "quit closes the browser that came up under it")
        #expect(log.records(named: Self.name).map(\.phase) == [.asyncBegin, .asyncEnd])
        #expect(runtime.spareWindow.createTrace.openCount == 0)
        runtime.handle(.beforeClose(browser: 10))
        await quit.value
    }

    @Test func aHostModeCreateQuitStopsWaitingForEndsAtQuit() async throws {
        let (runtime, root, log) = try Self.spyRuntime(hostMode: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = Self.paneHost(runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        host.ensureCreated(tab)
        #expect(runtime.spareWindow.createTrace.openCount == 1)

        await runtime.shutdown(timeout: .milliseconds(200))

        #expect(log.records(named: Self.name).map(\.phase) == [.asyncBegin, .asyncEnd], "no reply came before the wait ran out")
        #expect(runtime.spareWindow.createTrace.openCount == 0)
    }

    @Test func eachProfilesCreateCarriesItsIndex() throws {
        let (runtime, root, log) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        for profile in [BrowserProfileID(rawValue: UUID()), BrowserProfileID(rawValue: UUID())] {
            let host = Self.paneHost(runtime, profile: profile)
            let tab = CEFTab(id: .random(), profile: profile, host: host, runtime: runtime)
            host.add(tab)
            host.ensureCreated(tab)
        }
        #expect(CreateSpy.windowCreates == 2)
        let begins = log.records(named: Self.name).filter { $0.phase == .asyncBegin }
        #expect(begins.map(\.arg0) == [CEFCreateBrowserTrace.beginArg0(spare: false, profileIndex: 1),
                                         CEFCreateBrowserTrace.beginArg0(spare: false, profileIndex: 2)])
    }

    @Test func aHostModeCreateThatWasNotSentEndsAtOnce() throws {
        let (runtime, root, log) = try Self.spyRuntime(hostMode: true, started: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = Self.paneHost(runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        host.ensureCreated(tab)
        #expect(log.records(named: Self.name).map(\.phase) == [.asyncBegin, .asyncEnd])
        #expect(runtime.spareWindow.createTrace.openCount == 0)
        #expect(runtime.pendingWindows.isEmpty)
    }

    @Test func withTheCefCategoryOffACreateWritesNothing() throws {
        let (runtime, root, log) = try Self.spyRuntime(hostMode: true, categoryOn: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = Self.paneHost(runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        host.ensureCreated(tab)
        try Self.comeUp(runtime, browser: 10)
        #expect(log.records(named: Self.name).isEmpty)
        #expect(runtime.spareWindow.createTrace.openCount == 0)
    }

    @Test func profilesAreNumberedInTheOrderOfTheirFirstWindow() {
        let trace = CEFCreateBrowserTrace(signposter: Signposter(category: .cef, trace: TraceRuntime(role: .app)))
        let first = BrowserProfileID(rawValue: UUID()), second = BrowserProfileID(rawValue: UUID())
        #expect(trace.profileIndex(of: .default) == 0)
        #expect(trace.profileIndex(of: first) == 1)
        #expect(trace.profileIndex(of: second) == 2)
        #expect(trace.profileIndex(of: first) == 1)
        #expect(trace.profileIndex(of: .default) == 0)
        #expect(CEFCreateBrowserTrace.beginArg0(spare: true, profileIndex: 2) == 0x201)
    }

    /// A pane's host of `profile` (no spare is up, so it builds its own window).
    private static func paneHost(_ runtime: CEFRuntime, profile: BrowserProfileID = .default) -> CEFPaneHost {
        runtime.host(for: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: profile))
    }

    /// Chromium finished the one window being built: its OnAfterCreated, as `browser`.
    private static func comeUp(_ runtime: CEFRuntime, browser: Int32) throws {
        #expect(runtime.pendingWindows.count == 1)
        let request = try #require(runtime.pendingWindows.keys.first)
        runtime.handle(.afterCreated(browser: browser, request: request, window: browser))
    }

    /// A runtime that outlives the test (a window that came up shows itself at the end of the turn), whose
    /// `cef.create_browser` pairs go to the returned log. `hostMode` puts it in host mode (a supervisor that is
    /// never asked: the spy shim stands in for the remote one); `started` is what each create returns.
    private static func spyRuntime(hostMode: Bool = false, started: Int32 = 1,
                                   categoryOn: Bool = true) throws -> (CEFRuntime, URL, CreateRecordLog) {
        CreateSpy.reset(started: started)
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-create-browser-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(shim: try CreateSpy.library(), storage: CEFProfileStorage(root: root))
        if hostMode { runtime.hostStart = CEFHostStart(supervisor: UnaskedSupervisor()) }
        let log = CreateRecordLog()
        let trace = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { log.append($0) })
        if categoryOn { trace.setCategoryMask(1 << UInt64(SignpostCategory.cef.traceBit)) }
        runtime.spareWindow.createTrace = CEFCreateBrowserTrace(signposter: Signposter(category: .cef, trace: trace))
        _ = Unmanaged.passRetained(runtime)
        return (runtime, root, log)
    }
}

/// The records a test's trace runtime writes, in order.
private nonisolated final class CreateRecordLog: Sendable {
    private let state = Mutex<[TraceRuntime.StubRecord]>([])

    func append(_ record: TraceRuntime.StubRecord) { state.withLock { $0.append(record) } }

    func records(named name: UInt16) -> [TraceRuntime.StubRecord] { state.withLock { $0.filter { $0.name == name } } }
}

/// Host mode's supervisor in these tests: the runtime is never started, so it is never asked.
private final class UnaskedSupervisor: ChromiumHostSupervising {
    func attachment() async throws(ChromiumHostAttachError) -> ChromiumHostAttachment {
        throw .cannotStart("not used in CEFPaneHostTests")
    }

    func observeHostEnds(_ ended: @escaping @MainActor () -> Void) {}
}

/// Stand-in shim: window creates return `started` and closes are recorded; every other function does
/// nothing and returns 0.
private nonisolated enum CreateSpy {
    nonisolated(unsafe) static var started: Int32 = 1
    nonisolated(unsafe) static var windowCreates = 0
    nonisolated(unsafe) static var closed: [Int32] = []

    static func reset(started value: Int32) {
        started = value
        windowCreates = 0
        closed = []
    }

    static func library() throws -> CEFShimLibrary {
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in
            CreateSpy.windowCreates += 1
            return CreateSpy.started
        }
        let close: @convention(c) (Int32) -> Void = { CreateSpy.closed.append($0) }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_close": unsafeBitCast(close, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
