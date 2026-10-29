#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
import AppKit
@testable import CmuxNextBrowser
import CmuxNextWakeups
import Darwin
import Foundation
import Testing

/// The navigation mirrors of the Chromium Host in the real host process:
/// a Debug app's `<Product> Chromium Host` runs Chromium, this process loads the app's
/// `libcmux_cef_shim_remote.dylib` (the shim ABI cmux loads in host mode, task 014), opens a
/// `file://` probe page, navigates it, and reads `cmux_shim_tab_navigation_state` and
/// `cmux_shim_tab_navigation_entries` inside the LOAD_START callback, as cmux's code reads them in
/// an event's turn. The host pushed both before that event with no watch from cmux, so the read
/// has the new entry.
///
/// Needs a built Debug app with the host embedded (`cmux-ci build cmux --ref SHA`):
/// `CMUX_NEXT_CHROMIUM_HOST_APP=<the .app> swift test --filter ChromiumHostMirror`. Without it the
/// test does nothing. The portable half of the same check, the dispatcher against the remote shim
/// on a socket pair, is scripts/cmux-next/tests/chromium-host-dispatch.test.sh.
/// The Debug app under test, outside the suite: a `@Suite` trait that names a member of its own
/// type is a circular macro reference.
private nonisolated let chromiumHostApp = ProcessInfo.processInfo.environment["CMUX_NEXT_CHROMIUM_HOST_APP"]
    .map { URL(filePath: $0, directoryHint: .isDirectory) }

@MainActor
@Suite(.serialized, .enabled(if: chromiumHostApp != nil, "needs CMUX_NEXT_CHROMIUM_HOST_APP"))
struct ChromiumHostMirrorHostProcessTests {
    nonisolated static var app: URL? { chromiumHostApp }

    // cmux_cef_shim.h event kinds (nonisolated: the @Sendable matchers of `next` read them).
    nonisolated static let afterCreated: Int32 = 2
    nonisolated static let loadStart: Int32 = 8
    nonisolated static let loadEnd: Int32 = 9

    @Test(.timeLimit(.minutes(3)))
    func aReadInLoadStartsTurnHasTheNewEntry() async throws {
        let app = try #require(Self.app)
        let frameworks = app.appending(path: "Contents/Frameworks")
        let layout = try #require(CEFRuntimeLayout.at(frameworks, fallbackMainBundle: app), "no CEF runtime in \(app.path)")
        let scratch = FileManager.default.temporaryDirectory.appending(path: "chromium-host-mirror-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let rootCache = scratch.appending(path: "root")
        try FileManager.default.createDirectory(at: rootCache, withIntermediateDirectories: true)
        let configuration = try #require(
            ChromiumHostConfiguration.bundled(in: layout, rootCache: rootCache, bundleIdentifier: Bundle(url: app)?.bundleIdentifier,
                                              environment: [:]),
            "no Chromium Host in \(app.path)")
        let first = scratch.appending(path: "probe1.html")
        let second = scratch.appending(path: "probe2.html")
        try Data("<title>one</title>probe one".utf8).write(to: first)
        try Data("<title>two</title>probe two".utf8).write(to: second)

        let shim = try HostModeRemoteShim(frameworks.appending(path: "libcmux_cef_shim_remote.dylib"))
        let recorder = HostMirrorRecorder(shim: shim)
        var signals = recorder.signals.makeAsyncIterator()
        let launcher = ChromiumHostLauncher()
        let handle = try await launcher.launch(executable: configuration.executable, arguments: configuration.arguments)
        // The host's fd 3 is one end of a socket pair: its control channel, both ways. Its fd 4 is unused.
        Darwin.close(handle.readFD)
        defer {
            shim.detach()  // the host ends when its channel does
            launcher.kill(handle.pid)
            launcher.reap(handle.pid)
        }
        recorder.configure()
        #expect(shim.attach(handle.writeFD, nil, nil) == 1, "the remote shim takes the host's wire")
        let switches = configuration.arguments.filter { $0.hasPrefix("--cef-switch=") }.map { String($0.dropFirst("--cef-switch=".count)) }
        #expect(recorder.initialize(layout: layout, rootCache: rootCache, logFile: configuration.logFile, switches: switches) == 1)
        let hello = await Self.next(&signals) { $0 == .ready }
        try #require(hello == .ready, "the host said hello")

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        #expect(shim.createWindow(42, Unmanaged.passUnretained(view).toOpaque(), 800, 600, first.absoluteString, nil) == 1)
        let created = await Self.next(&signals) { $0.event?.kind == Self.afterCreated && $0.event?.request == 42 }
        let tab = try #require(created?.event?.browser, "AFTER_CREATED for the probe page")
        #expect(tab >= 1 << 20, "the tab has cmux's minted id")
        _ = await Self.next(&signals) { $0.event?.kind == Self.loadEnd && $0.event?.browser == tab }
        let before = shim.navigationState(tab)
        #expect(before != nil, "the first page's history is cached")

        var stateAtLoadStart: String?
        var entriesAtLoadStart: String?
        recorder.onEvent = { event in
            guard event.kind == Self.loadStart, event.browser == tab, event.text.hasSuffix("probe2.html") else { return }
            stateAtLoadStart = shim.navigationState(tab)
            entriesAtLoadStart = shim.navigationEntries(tab)
        }
        shim.loadURL(tab, second.absoluteString)
        let loaded = await Self.next(&signals) { $0.event?.kind == Self.loadEnd && $0.event?.browser == tab }
        #expect(loaded != nil, "the second probe page loaded")
        recorder.onEvent = nil

        let state = try #require(stateAtLoadStart, "a history read in LOAD_START's turn")
        #expect(state != before, "the history read at LOAD_START is the new one")
        let entries = try #require(entriesAtLoadStart.flatMap { CEFNavigationEntries(json: $0) }, "Back/Forward entries at LOAD_START")
        let urls = entries.entries.map(\.url)
        #expect(urls.count == 2 && urls.last?.hasSuffix("probe2.html") == true, "the new entry is the last: \(urls)")
        withExtendedLifetime(view) {}
    }

    /// The next signal that matches, or nil when the wire ended first. `@concurrent`, like
    /// `AsyncStream.Iterator.next()`: the caller sends its iterator here once and the reads do not
    /// hop isolation again (the target's default isolation is the main actor), as
    /// BranchSizedForTests.notice does.
    @concurrent nonisolated static func next(_ signals: inout AsyncStream<HostMirrorRecorder.Signal>.Iterator,
                                             _ match: @Sendable (HostMirrorRecorder.Signal) -> Bool) async -> HostMirrorRecorder.Signal? {
        while let signal = await signals.next() {
            if match(signal) { return signal }
            if case .ended = signal { return nil }
        }
        return nil
    }
}

/// The remote shim's exports this test calls, bound by name from the dylib cmux loads in host mode.
/// The dylib is never closed: its runtime is per process.
@MainActor
final class HostModeRemoteShim {
    typealias MainTaskFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias PostMainFn = @convention(c) (UnsafeMutableRawPointer?, MainTaskFn?, UnsafeMutableRawPointer?) -> Void
    typealias ReadyFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias EndedFn = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
    typealias EventFn = @convention(c) (UnsafeMutableRawPointer?, Int32, Int32, Int32, Int64, Int64,
                                        UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
    typealias ConfigureFn = @convention(c) (UnsafeRawPointer?) -> Void
    typealias AttachFn = @convention(c) (Int32, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32
    typealias DetachFn = @convention(c) () -> Void
    typealias InitializeFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
                                             UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?,
                                             UnsafePointer<CChar>?, UnsafePointer<UnsafePointer<CChar>?>?,
                                             UnsafeMutableRawPointer?, UnsafeRawPointer?, EventFn?, UnsafeRawPointer?) -> Int32
    typealias CreateWindowFn = @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?,
                                               UnsafePointer<CChar>?) -> Int32
    typealias LoadURLFn = @convention(c) (Int32, UnsafePointer<CChar>?) -> Void
    typealias StringMirrorFn = @convention(c) (Int32) -> UnsafeMutablePointer<CChar>?
    typealias FreeFn = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void

    nonisolated enum LoadError: Error {
        case open(String)
        case missingSymbol(String)
    }

    let configure: ConfigureFn
    let attach: AttachFn
    let detach: DetachFn
    let initialize: InitializeFn
    let createWindow: CreateWindowFn
    let loadURL: LoadURLFn
    private let tabNavigationState: StringMirrorFn
    private let tabNavigationEntries: StringMirrorFn
    private let freeString: FreeFn

    init(_ dylib: URL) throws(LoadError) {
        guard let handle = dlopen(dylib.path, RTLD_NOW | RTLD_LOCAL) else {
            throw .open(dlerror().map { String(cString: $0) } ?? dylib.path)
        }
        func resolve<T>(_ name: String) throws(LoadError) -> T {
            guard let pointer = dlsym(handle, name) else { throw .missingSymbol(name) }
            return unsafeBitCast(pointer, to: T.self)
        }
        configure = try resolve("cmux_remote_shim_configure")
        attach = try resolve("cmux_remote_shim_attach")
        detach = try resolve("cmux_remote_shim_detach")
        initialize = try resolve("cmux_shim_initialize")
        createWindow = try resolve("cmux_shim_create_window")
        loadURL = try resolve("cmux_shim_load_url")
        tabNavigationState = try resolve("cmux_shim_tab_navigation_state")
        tabNavigationEntries = try resolve("cmux_shim_tab_navigation_entries")
        freeString = try resolve("cmux_shim_free")
    }

    /// What the remote shim's mirror cache holds, nil for no value.
    func navigationState(_ browser: Int32) -> String? { take(tabNavigationState(browser)) }
    func navigationEntries(_ browser: Int32) -> String? { take(tabNavigationEntries(browser)) }

    private func take(_ text: UnsafeMutablePointer<CChar>?) -> String? {
        guard let text else { return nil }
        defer { freeString(text) }
        return String(cString: text)
    }
}

/// The remote shim's callbacks for one host: its hello, its end and every event, on the main
/// thread (the remote shim runs them in the tasks it posts), in order, as a stream.
@MainActor
final class HostMirrorRecorder {
    nonisolated struct Event: Equatable, Sendable {
        var kind: Int32
        var browser: Int32
        var request: Int32
        var text: String
    }

    nonisolated enum Signal: Equatable, Sendable {
        case ready
        case ended(Int32)
        case event(Event)

        var event: Event? {
            if case .event(let event) = self { event } else { nil }
        }
    }

    let shim: HostModeRemoteShim
    let signals: AsyncStream<Signal>
    /// Runs inside the event's callback, before the stream sees it: where cmux's code reads mirrors.
    var onEvent: ((Event) -> Void)?
    private let continuation: AsyncStream<Signal>.Continuation

    init(shim: HostModeRemoteShim) {
        self.shim = shim
        let (signals, continuation) = AsyncStream<Signal>.makeStream()
        self.signals = signals
        self.continuation = continuation
    }

    /// cmux_remote_shim_configure (remote_shim_runtime.h's cmux_remote_shim_callbacks: ctx,
    /// post_main, ready, reply, ended, five pointers); the shim copies them.
    func configure() {
        let callbacks = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: 5)
        defer { callbacks.deallocate() }
        callbacks[0] = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
        callbacks[1] = unsafeBitCast(remoteShimPostMain, to: UnsafeRawPointer.self)
        callbacks[2] = unsafeBitCast(remoteShimReady, to: UnsafeRawPointer.self)
        callbacks[3] = nil  // reply: no awaited op here
        callbacks[4] = unsafeBitCast(remoteShimEnded, to: UnsafeRawPointer.self)
        shim.configure(UnsafeRawPointer(callbacks))
    }

    /// cmux_shim_initialize as CEFRuntime calls it, with this recorder's event callback. The
    /// remote shim copies every string into its INITIALIZE frame before it returns.
    func initialize(layout: CEFRuntimeLayout, rootCache: URL, logFile: String?, switches: [String]) -> Int32 {
        var strings: [UnsafeMutablePointer<CChar>?] = []
        defer { strings.forEach { Darwin.free($0) } }
        func keep(_ text: String?) -> UnsafePointer<CChar>? {
            guard let text else { return nil }
            let copy = strdup(text)
            strings.append(copy)
            return UnsafePointer(copy)
        }
        let list: [UnsafePointer<CChar>?] = switches.map { keep($0) } + [nil]
        let context = Unmanaged.passUnretained(self).toOpaque()
        return list.withUnsafeBufferPointer { buffer in
            shim.initialize(keep(layout.frameworkDirectory.path), keep(layout.mainBundle.path), keep(layout.helperExecutable.path),
                            keep(rootCache.path), keep(logFile), 1, keep("en-US"), keep("en-US,en"), buffer.baseAddress, context,
                            nil, remoteShimEvent, nil)
        }
    }

    func deliver(_ signal: Signal) {
        if let event = signal.event { onEvent?(event) }
        continuation.yield(signal)
    }

    static func from(_ address: UInt) -> HostMirrorRecorder? {
        UnsafeMutableRawPointer(bitPattern: address).map { Unmanaged<HostMirrorRecorder>.fromOpaque($0).takeUnretainedValue() }
    }
}

/// The remote shim's reader thread hands each batch to the main thread here, in order.
private let remoteShimPostMain: HostModeRemoteShim.PostMainFn = { _, run, task in
    // crash-allow: the shim's task and its C runner cross to the main thread once and run there exactly once (remote_shim_runtime.h, post_main)
    nonisolated(unsafe) let pending = (run, task)
    // main-hop-allow: cmux_remote_shim_callbacks.post_main's contract (FIFO, from the reader thread); a test process has no MainWorkScheduler
    MainDelivery().run { pending.0?(pending.1) }
}

private let remoteShimReady: HostModeRemoteShim.ReadyFn = { context in
    let address = UInt(bitPattern: context)
    MainActor.assumeIsolated { // main-proof: cmux_remote_shim_callbacks.ready runs on the main thread (remote_shim_runtime.h)
        HostMirrorRecorder.from(address)?.deliver(.ready)
    }
}

private let remoteShimEnded: HostModeRemoteShim.EndedFn = { context, reason in
    let address = UInt(bitPattern: context)
    MainActor.assumeIsolated { // main-proof: cmux_remote_shim_callbacks.ended runs on the main thread (remote_shim_runtime.h)
        HostMirrorRecorder.from(address)?.deliver(.ended(reason))
    }
}

private let remoteShimEvent: HostModeRemoteShim.EventFn = { context, kind, browser, request, _, _, text, _ in
    let address = UInt(bitPattern: context)
    let event = HostMirrorRecorder.Event(kind: kind, browser: browser, request: request, text: text.map { String(cString: $0) } ?? "")
    MainActor.assumeIsolated { // main-proof: the remote shim delivers EVENT frames in its main-thread tasks (remote_shim.mm Apply)
        HostMirrorRecorder.from(address)?.deliver(.event(event))
    }
}
#endif
