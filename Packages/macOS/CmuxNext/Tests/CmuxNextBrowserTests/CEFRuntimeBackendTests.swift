@testable import CmuxNextBrowser
import Darwin
import Foundation
import Testing

/// Host mode (``BrowserBackend/host``, task 015 of plans/cmux-next/chrome-parity/p01-process.md):
/// `CEFRuntime.start` takes the Chromium Host's wire from the supervisor, opens and attaches the
/// remote shim and initializes through it. It never runs the in-process load (no
/// `CEFLoadedLibrary`, no framework), never prepares NSApp and starts no pump. The remote shim's
/// ABI identity is checked as the in-process shim's is. Against a fake supervisor and a spy shim.
@MainActor @Suite(.serialized) struct CEFRuntimeBackendTests {
    @Test func hostModeNeverBuildsTheInProcessLibrary() async throws {
        RemoteSpy.reset()
        let wire = try Wire()
        defer { wire.close() }
        let supervisor = FakeSupervisor(controlFD: wire.fd)
        let runtime = Self.runtime(supervisor: supervisor)

        try await runtime.start(layout: nil, environment: [:], trigger: "test")

        #expect(RemoteSpy.inProcessLoads == 0, "host mode built a CEFLoadedLibrary")
        #expect(runtime.state == .ready)
        #expect(supervisor.asked == 1)
        #expect(RemoteSpy.attachedFDs == [wire.fd])
        #expect(runtime.pump == nil, "host mode started the message pump")
        #expect(runtime.layout == nil, "host mode resolved the framework layout")
        #expect(RemoteSpy.prepareApplicationCalls == 0)
        #expect(RemoteSpy.initializeFrameworkPaths == [""], "host mode sent a framework path to initialize")
        #expect(runtime.forkAPIVersion == RemoteSpy.forkAPI, "the fork version is the host's, read after attach")
    }

    @Test func concurrentStartsAttachOnce() async throws {
        RemoteSpy.reset()
        let wire = try Wire()
        defer { wire.close() }
        let supervisor = FakeSupervisor(controlFD: wire.fd)
        let runtime = Self.runtime(supervisor: supervisor)

        let first = Task { try await runtime.start(layout: nil, environment: [:], trigger: "tab") }
        let second = Task { try await runtime.start(layout: nil, environment: [:], trigger: "warm") }
        try await first.value
        try await second.value

        #expect(supervisor.asked == 1)
        #expect(RemoteSpy.attachedFDs.count == 1)
        #expect(RemoteSpy.initializeFrameworkPaths.count == 1)
        #expect(RemoteSpy.inProcessLoads == 0)
    }

    /// A host that cannot start fails the start; Chromium never falls back into this process.
    @Test func aHostThatCannotStartFailsWithoutLoadingInProcess() async {
        RemoteSpy.reset()
        let supervisor = FakeSupervisor(controlFD: -1)
        supervisor.failure = .cannotStart("no host executable")
        let runtime = Self.runtime(supervisor: supervisor)

        await #expect(throws: BrowserEngineError.self) {
            try await runtime.start(layout: nil, environment: [:], trigger: "test")
        }

        guard case .failed = runtime.state else {
            Issue.record("state \(runtime.state), expected failed")
            return
        }
        #expect(RemoteSpy.inProcessLoads == 0)
        #expect(RemoteSpy.attachedFDs.isEmpty)
        #expect(runtime.shim == nil)
    }

    /// The control case: without a supervisor the start is the in-process load.
    @Test func inProcessModeRunsTheInProcessLoad() async {
        RemoteSpy.reset()
        let runtime = CEFRuntime(storage: CEFProfileStorage(root: Self.scratch()))
        runtime.loadInProcess = { _ in
            RemoteSpy.inProcessLoads += 1
            return .failure(.notEmbedded)
        }

        await #expect(throws: BrowserEngineError.self) {
            try await runtime.start(layout: nil, environment: [:], trigger: "test")
        }

        #expect(RemoteSpy.inProcessLoads == 1)
        #expect(runtime.hostStart == nil)
    }

    @Test func theRemoteShimChecksTheSameABIIdentity() throws {
        RemoteSpy.reset()
        #expect(throws: CEFShimLibrary.LoadError.abiMismatch(expected: "another header", found: RemoteSpy.abi)) {
            try CEFRemoteShim.make(symbol: RemoteSpy.symbol, expected: "another header")
        }
        #expect(throws: CEFShimLibrary.LoadError.abiMismatch(expected: "missing", found: RemoteSpy.abi)) {
            try CEFRemoteShim.make(symbol: RemoteSpy.symbol, expected: nil)
        }
        _ = try CEFRemoteShim.make(symbol: RemoteSpy.symbol, expected: RemoteSpy.abi)
    }

    @Test func aRemoteShimWithoutTheWireEntryPointsDoesNotLoad() {
        #expect(throws: CEFShimLibrary.LoadError.missingSymbol("cmux_remote_shim_attach")) {
            try CEFRemoteShim.make(symbol: { $0 == "cmux_remote_shim_attach" ? nil : RemoteSpy.symbol($0) }, expected: RemoteSpy.abi)
        }
    }

    /// The remote dylib exports every optional call; only the host shim's (its hello) count.
    @Test func optionalExportsComeFromTheHostsHello() throws {
        let none = try CEFShimLibrary.resolving(RemoteSpy.symbol, hostExports: [])
        #expect(!none.hasRendererPaths)
        #expect(none.pageSchemeSetGroup == nil)
        #expect(!CEFForkFeatures(forkAPIVersion: RemoteSpy.forkAPI, shimHasRendererPaths: none.hasRendererPaths).rendererPaths)

        let all = try CEFShimLibrary.resolving(RemoteSpy.symbol, hostExports: RemoteSpy.rendererPathExports)
        #expect(all.hasRendererPaths)
        #expect(all.pageSchemeSetGroup == nil)
    }

    @Test func theSourcesSupervisorPicksTheBackend() {
        #expect(CEFRuntimeSource(layout: nil).backend == .inProcess)
        #expect(CEFRuntimeSource(layout: nil, hostSupervisor: FakeSupervisor(controlFD: -1)).backend == .host)
    }

    /// Chromium starts once per process: a runtime that already started keeps its backend.
    @Test func aStartedRuntimeIgnoresALaterSupervisor() throws {
        let runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(RemoteSpy.symbol), storage: CEFProfileStorage(root: Self.scratch()))
        runtime.adopt(stores: .inMemory(), signInCallbacks: CEFSignInCallbacks(), hostSupervisor: FakeSupervisor(controlFD: -1))
        #expect(runtime.hostStart == nil)
    }

    private static func scratch() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "cef-backend-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// A runtime in host mode whose in-process load only counts its calls.
    private static func runtime(supervisor: FakeSupervisor) -> CEFRuntime {
        let runtime = CEFRuntime(storage: CEFProfileStorage(root: scratch()))
        runtime.loadInProcess = { _ in
            RemoteSpy.inProcessLoads += 1
            return .failure(.notEmbedded)
        }
        runtime.hostStart = CEFHostStart(supervisor: supervisor, open: { _ in
            do { return .success(try CEFRemoteShim.make(symbol: RemoteSpy.symbol, expected: RemoteSpy.abi)) } catch { return .failure(.shim(error)) }
        })
        return runtime
    }
}

/// A pipe whose read end stands in for the host's control socket.
private struct Wire {
    let fd: Int32
    private let other: Int32

    init() throws {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw POSIXError(.EMFILE) }
        fd = fds[0]
        other = fds[1]
    }

    func close() {
        Darwin.close(fd)
        Darwin.close(other)
    }
}

/// The supervisor's side: hands out one attachment per request, or fails.
@MainActor
private final class FakeSupervisor: ChromiumHostSupervising {
    let controlFD: Int32
    var failure: ChromiumHostAttachError?
    private(set) var asked = 0

    init(controlFD: Int32) {
        self.controlFD = controlFD
    }

    func attachment() async throws(ChromiumHostAttachError) -> ChromiumHostAttachment {
        asked += 1
        if let failure { throw failure }
        return ChromiumHostAttachment(controlFD: controlFD, remoteShim: URL(filePath: "/nonexistent/libcmux_cef_shim_remote.dylib"),
                                      frameworkLocales: ["en.lproj", "ja.lproj"])
    }
}

/// The remote dylib's functions: the ABI id, attach (records the control descriptor and says hello
/// at once with no optional exports), the fork API version, and recorders for prepare_application,
/// initialize and the in-process load; every other function does nothing and returns 0.
private nonisolated enum RemoteSpy {
    static let abi = "remote-spy-abi"
    static let forkAPI: Int32 = 30
    static let rendererPathExports: Set<String> = [
        "cmux_shim_add_document_script", "cmux_shim_add_page_channel", "cmux_shim_tab_evaluate",
        "cmux_shim_tab_set_frozen", "cmux_shim_tab_send_click", "cmux_shim_tab_set_color_scheme",
    ]
    nonisolated(unsafe) static var inProcessLoads = 0
    nonisolated(unsafe) static var attachedFDs: [Int32] = []
    nonisolated(unsafe) static var prepareApplicationCalls = 0
    nonisolated(unsafe) static var initializeFrameworkPaths: [String] = []
    nonisolated(unsafe) private static let abiCString = strdup(abi)

    static func reset() {
        inProcessLoads = 0
        attachedFDs = []
        prepareApplicationCalls = 0
        initializeFrameworkPaths = []
    }

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let abiID: @convention(c) () -> UnsafePointer<CChar>? = { UnsafePointer(RemoteSpy.abiCString) }
        let attach: CEFRemoteShim.AttachFn = { control, _, _, context, hello in
            RemoteSpy.attachedFDs.append(control)
            hello?(context, 1, nil)
            return 1
        }
        let forkAPIVersion: @convention(c) () -> Int32 = { RemoteSpy.forkAPI }
        let prepareApplication: @convention(c) () -> Int32 = {
            RemoteSpy.prepareApplicationCalls += 1
            return 1
        }
        let initialize: @convention(c) (
            UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
            UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
            UnsafePointer<UnsafePointer<CChar>?>?,
            UnsafeMutableRawPointer?, CEFShimLibrary.ScheduleFn?, CEFShimLibrary.EventFn?, CEFShimLibrary.KeyFn?
        ) -> Int32 = { framework, _, _, _, _, _, _, _, _, _, _, _, _ in
            RemoteSpy.initializeFrameworkPaths.append(framework.map { String(cString: $0) } ?? "nil")
            return 1
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_shim_abi_id": unsafeBitCast(abiID, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_attach": unsafeBitCast(attach, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_fork_api_version": unsafeBitCast(forkAPIVersion, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_prepare_application": unsafeBitCast(prepareApplication, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_initialize": unsafeBitCast(initialize, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
