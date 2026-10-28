@testable import CmuxNextBrowser
import CmuxNextMetrics
@testable import CmuxNextTrace
import Darwin
import Foundation
import Testing

/// The Chromium Host's helpers: their ends come as HELPER_EXIT (kind 68, HOST/src/
/// host_helper_exits.h), which decodes to the in-process child monitor's ``CEFChildProcessMonitor/Exit`` and makes
/// the same `debug.crashes` record and `cef.helper_exit` sample, and the tabs' process list reads the host's
/// children. Each test records into its own store.
extension CEFPumpTests {
    /// A ready runtime whose samples go to the returned store. It outlives the test, as `exitRig` does.
    private static func hostHelperRig() throws -> (CEFRuntime, MetricsStore) {
        let trace = TraceRuntime(role: .app)
        let store = Self.store(on: trace)
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-host-helper-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(SilentShim.symbol), storage: CEFProfileStorage(root: root))
        runtime.helperExits = CEFHelperExitMetric(metrics: Metrics(runtime: trace))
        _ = Unmanaged.passRetained(runtime)
        return (runtime, store)
    }

    /// HELPER_EXIT as the host sends it: no browser, the pid as the request, the wait status, the extension flag, the
    /// helper's `--type` and `--utility-sub-type`.
    private static func helperExit(pid: Int32, status: Int32, extension isExtension: Bool = false, type: String,
                                   subType: String = "") -> CEFShimEvent {
        CEFShimEvent(kind: 68, browser: 0, request: pid, a: Int64(status), b: isExtension ? 1 : 0, s1: type, s2: subType)
    }

    @Test func helperExitDecodesToTheMonitorsExit() {
        #expect(Self.helperExit(pid: 4242, status: SIGKILL, type: "gpu-process")
                == .helperExit(CEFChildProcessMonitor.Exit(pid: 4242, processType: "gpu-process", subType: nil,
                                                           isExtension: false, status: SIGKILL)))
        #expect(Self.helperExit(pid: 4243, status: SIGSEGV, type: "utility", subType: "network.mojom.NetworkService")
                == .helperExit(CEFChildProcessMonitor.Exit(pid: 4243, processType: "utility", subType: "network.mojom.NetworkService",
                                                           isExtension: false, status: SIGSEGV)))
        #expect(Self.helperExit(pid: 4244, status: 1 << 8, extension: true, type: "renderer")
                == .helperExit(CEFChildProcessMonitor.Exit(pid: 4244, processType: "renderer", subType: nil,
                                                           isExtension: true, status: 1 << 8)))
        #expect(Self.helperExit(pid: 4245, status: SIGKILL, type: "") == .unknown(kind: 68), "no type: not a helper")
        #expect(Self.helperExit(pid: 0, status: SIGKILL, type: "renderer") == .unknown(kind: 68), "no pid")
        #expect(Self.helperExit(pid: 4242, status: SIGKILL, type: "gpu-process").browserID == nil, "about no tab")
    }

    /// The acceptance: a SIGKILLed GPU helper and renderer of the host each make one `debug.crashes` record with their
    /// type, pid and signal. The GPU end is its `cef.helper_exit` sample; the renderer's sample is RENDER_TERMINATED's,
    /// as in process.
    @Test func aKilledHostHelperMakesOneCrashRecord() throws {
        let (runtime, store) = try Self.hostHelperRig()
        runtime.handle(Self.helperExit(pid: 4242, status: SIGKILL, type: "gpu-process"))
        runtime.handle(Self.helperExit(pid: 4243, status: SIGKILL, type: "renderer"))
        runtime.handle(Self.helperExit(pid: 4244, status: SIGTERM, type: "utility"))  // Chromium ended it: normal
        let records = runtime.crashLog.records
        #expect(records.map(\.processType) == ["gpu-process", "renderer"])
        #expect(records.map(\.pid) == [4242, 4243])
        #expect(records.allSatisfy { $0.reason == .killed && $0.code == Int(SIGKILL) && $0.source == .process })
        let buckets = Self.histogram(.cefHelperExit, in: store)?.buckets ?? []
        #expect(buckets.map(\.index) == [Int(CEFHelperExitMetric.sample(.gpu, .killed))] && buckets.map(\.count) == [1])
    }

    @Test func quitsHostHelperEndsRecordNothing() throws {
        let (runtime, _) = try Self.hostHelperRig()
        runtime.shutdownSequence = CEFShutdownSequence(liveBrowsers: 1, windows: 1)
        runtime.handle(Self.helperExit(pid: 4242, status: SIGKILL, type: "gpu-process"))
        runtime.shutdownSequence = nil
        #expect(runtime.crashLog.records.isEmpty)
    }

    /// In process the helpers are the app's children; in host mode they are the attached host's, and none while no host
    /// is attached. The runtime publishes the parent where listings off the main actor read it.
    @Test func theHelpersParentIsTheAppInProcess() throws {
        let (runtime, _) = try Self.hostHelperRig()
        #expect(runtime.helperParentPID == getpid())
        #expect(runtime.helperParent.pid == getpid())
        runtime.hostStart = CEFHostStart(supervisor: NoHostSupervisor())
        #expect(runtime.helperParentPID == nil, "host mode with no host attached")
        #expect(runtime.helperParent.pid == nil, "published as host mode starts")
    }

    /// A source's parent before any runtime adopts it: the app in process, none in host mode.
    @Test func aSourcesHelperParentFollowsItsBackend() {
        #expect(CEFRuntimeSource(layout: nil).helperParent.pid == getpid())
        #expect(CEFRuntimeSource(layout: nil, hostSupervisor: NoHostSupervisor()).helperParent.pid == nil)
    }
}

/// A supervisor that never starts a host.
@MainActor private final class NoHostSupervisor: ChromiumHostSupervising {
    func attachment() async throws(ChromiumHostAttachError) -> ChromiumHostAttachment {
        throw .cannotStart("no host in this test")
    }

    func observeHostEnds(_ ended: @escaping @MainActor () -> Void) {}
}

/// A shim whose every export does nothing and returns 0.
private nonisolated enum SilentShim {
    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let nothing: @convention(c) () -> Int = { 0 }
        return unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
    }
}
