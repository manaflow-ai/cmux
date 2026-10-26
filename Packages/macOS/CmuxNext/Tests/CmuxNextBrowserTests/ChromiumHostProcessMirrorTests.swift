@testable import CmuxNextBrowser
import Darwin
import os
import Testing

/// The Chromium host's helper frames (HELPER_START, HELPER_EXIT,
/// RENDERER_CLIENTS) as cmux's mirror reads them. The payloads are the ones
/// CEFShim/tests/chromium_host_wire_test.cpp encodes on the host side.
@MainActor
@Suite struct ChromiumHostProcessMirrorTests {
    private static func start(_ pid: Int32, _ payload: String, client: Int32 = 0, isExtension: Bool = false) -> ChromiumHostFrame {
        ChromiumHostFrame(.helperStart, v: [pid, client, isExtension ? 1 : 0], payload: Array(payload.utf8))
    }

    private static func ended(_ pid: Int32, _ payload: String, status: Int32) -> ChromiumHostFrame {
        let signal = status & 0x7f
        return ChromiumHostFrame(.helperExit, v: [pid, status, signal, signal == 0 ? (status >> 8) & 0xff : 0, 0],
                                 payload: Array(payload.utf8))
    }

    private static func clients(browser: Int32, _ ids: [Int32]) -> ChromiumHostFrame {
        var bytes: [UInt8] = []
        for id in ids { withUnsafeBytes(of: UInt32(bitPattern: id).littleEndian) { bytes.append(contentsOf: $0) } }
        return ChromiumHostFrame(.rendererClients, v: [browser, Int32(ids.count)], payload: bytes)
    }

    @Test func helperStartsListTheHostsHelpersByKind() {
        let mirror = ChromiumHostProcessMirror()
        mirror.apply(Self.start(30, "gpu-process"))
        mirror.apply(Self.start(31, "utility\nnetwork.mojom.NetworkService"))
        mirror.apply(Self.start(32, "utility\nstorage.mojom.StorageService"))
        mirror.apply(Self.start(33, "renderer", client: 7))
        mirror.apply(Self.start(34, "renderer", client: 3, isExtension: true))
        #expect(mirror.processes == [
            ChromiumHelperProcess(pid: 30, kind: .gpu),
            ChromiumHelperProcess(pid: 31, kind: .network),
            ChromiumHelperProcess(pid: 32, kind: .utility),
            ChromiumHelperProcess(pid: 33, kind: .renderer(clientID: 7)),
            ChromiumHelperProcess(pid: 34, kind: .extensionRenderer),
        ])
        #expect(mirror.refusedFrames == 0)
    }

    @Test func rendererClientsComeFromTheMirrorNotTheWire() {
        let mirror = ChromiumHostProcessMirror()
        // The bytes chromium_host_wire_test.cpp checks EncodeClientIDs({7, 0x01020304}) against.
        mirror.apply(ChromiumHostFrame(.rendererClients, v: [1, 2], payload: [7, 0, 0, 0, 4, 3, 2, 1]))
        #expect(mirror.rendererClients(browser: 1) == [7, 0x01020304])
        mirror.apply(Self.clients(browser: 1, []))
        #expect(mirror.rendererClients(browser: 1).isEmpty)
        // A count that does not match the payload is refused, and the old list stays.
        mirror.apply(Self.clients(browser: 2, [9]))
        mirror.apply(ChromiumHostFrame(.rendererClients, v: [2, 3], payload: [1, 0, 0, 0]))
        #expect(mirror.rendererClients(browser: 2) == [9])
        #expect(mirror.refusedFrames == 1)
    }

    @Test func theTabProcessListShowsHostChildPids() {
        let mirror = ChromiumHostProcessMirror()
        mirror.apply(Self.start(40, "renderer", client: 5))
        mirror.apply(Self.start(41, "renderer", client: 6))
        mirror.apply(Self.start(42, "gpu-process"))
        mirror.apply(Self.clients(browser: 1, [6]))
        #expect(mirror.report["page_renderer_pids"] as? [Int] == [41])
        #expect(mirror.report["renderer_clients"] as? [Int] == [6])
        #expect((mirror.report["processes"] as? [[String: Any]])?.count == 3)
    }

    @Test func aHelperExitCarriesItsTypeAndSignal() throws {
        let mirror = ChromiumHostProcessMirror()
        mirror.apply(Self.start(50, "gpu-process"))
        let gpu = try #require(mirror.apply(Self.ended(50, "gpu-process", status: SIGKILL)))
        #expect(gpu == CEFChildProcessMonitor.Exit(pid: 50, processType: "gpu-process", subType: nil, isExtension: false, status: SIGKILL))
        #expect(gpu.signal == SIGKILL)
        #expect(mirror.processes.isEmpty)
        // An exit whose start the mirror missed still names the helper from its own payload.
        let utility = try #require(mirror.apply(Self.ended(51, "utility\nnetwork.mojom.NetworkService", status: 0x8b)))
        #expect(utility.subType == "network.mojom.NetworkService")
        #expect(utility.signal == SIGSEGV)
        #expect(mirror.apply(Self.ended(52, "", status: SIGKILL)) == nil)
        #expect(mirror.refusedFrames == 1)
    }

    @Test func onlyAbnormalEndsAreCrashes() {
        func reason(_ status: Int32) -> BrowserProcessExit.Reason? {
            CEFChildProcessMonitor.Exit(pid: 1, processType: "renderer", isExtension: false, status: status).abnormalReason
        }
        #expect(reason(SIGKILL) == .killed)
        #expect(reason(0x8b) == .crashed)  // SIGSEGV with a core
        #expect(reason(SIGTRAP) == .crashed)  // a CHECK
        #expect(reason(SIGTERM) == nil)  // Chromium ends helpers it no longer needs
        #expect(reason(0) == nil)
        #expect(reason(0x300) == .abnormal)  // exit 3
        #expect(reason(0x137f) == nil)  // stopped, not ended
    }

    @Test func aKilledHelperMakesOneCrashRecord() {
        let log = BrowserCrashLog()
        let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "tests")
        let killed = CEFChildProcessMonitor.Exit(pid: 60, processType: "gpu-process", isExtension: false, status: SIGKILL)
        #expect(killed.record(in: log, logger: logger))
        let ended = CEFChildProcessMonitor.Exit(pid: 61, processType: "renderer", isExtension: false, status: SIGTERM)
        #expect(!ended.record(in: log, logger: logger))
        #expect(log.total == 1)
        #expect(log.records.first?.processType == "gpu-process")
        #expect(log.records.first?.pid == 60)
        #expect(log.records.first?.source == .process)
        #expect(log.records.first?.codeDescription == "SIGKILL")
    }

    @Test func classifyingArgvAndIdentityAgree() {
        let argv = ["/x/Helper (Renderer)", "--type=renderer", "--renderer-client-id=12"]
        let identity = CEFHelperIdentity.parse(argv)
        #expect(ChromiumHelperProcess.classify(argv) == .renderer(clientID: 12))
        #expect(identity.map { ChromiumHelperProcess.kind(of: $0, rendererClientID: 12) } == .renderer(clientID: 12))
        #expect(ChromiumHelperProcess.classify(["--type=renderer"]) == .other)
    }
}
