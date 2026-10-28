@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextMemory
import Darwin
import Foundation
import Testing

/// Every listing of Chromium helpers reads the parent it is given: the app in process, the
/// Chromium Host in host mode (``ChromiumHelperParent``), none while no host is attached. A helper of the wrong
/// parent never shows: in host mode the app has no helper children, so a listing of the app's would show none.
@Suite(.serialized)
struct ChromiumHelperParentListingTests {
    /// A child of this process whose argv is a tab renderer's: `sh` waits for its `sleep`, so the switches stay its
    /// own arguments.
    private static func fakeRenderer(clientID: Int32) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 10; :", "--type=renderer", "--renderer-client-id=\(clientID)"]
        try process.run()
        return process
    }

    @Test func everyListingReadsTheParentItIsGiven() async throws {
        let renderer = try Self.fakeRenderer(clientID: 77)
        defer { renderer.terminate() }
        let pid = renderer.processIdentifier
        let helper = ChromiumHelperProcess(pid: pid, kind: .renderer(clientID: 77))

        #expect(ChromiumHelperProcess.list(parent: getpid()).contains(helper))
        #expect(!ChromiumHelperProcess.list(parent: pid).contains(helper), "another parent's children only")
        #expect(ChromiumHelperProcess.list(parent: nil).isEmpty, "host mode with no host attached")

        // The busy watchdog's and the hang reports' renderer map.
        #expect(AppProcesses.tabRendererClients(helperParent: getpid())[pid] == 77)
        #expect(AppProcesses.tabRendererClients(helperParent: nil).isEmpty)

        // The Energy Saver's busy hidden pages.
        #expect(ChromiumHelperProcess.tabRendererUsage(parent: getpid()).contains { $0.renderer == .init(pid: pid, clientID: 77) })
        #expect(ChromiumHelperProcess.tabRendererUsage(parent: nil).isEmpty)

        // The memory page's rows and its tab-to-renderer map.
        let memory = await AppMemoryModel.processes(webContentPIDs: [], helperParent: getpid())
        #expect(memory.rendererPIDs[77] == pid)
        #expect(memory.rows.contains { $0.kind == .chromiumRenderer && $0.pid == pid })
        let none = await AppMemoryModel.processes(webContentPIDs: [], helperParent: nil)
        #expect(none.rendererPIDs.isEmpty)
        #expect(none.rows.map(\.kind) == [.app])
    }
}
