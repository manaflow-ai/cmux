import AppKit
@testable import CmuxNextCompat
import CmuxNextCompatAppKit
import Foundation
import Testing
import UniformTypeIdentifiers

/// The checked NSWorkspace queries (CmuxNextCompatAppKit/Threading/NSWorkspace+Blocking.swift): on the main
/// thread each one records exactly one site at its caller's line; on a named serial queue none records. The
/// other system seams are in CmuxNextCompatTests' BlockingSystemSeamTests. The queries only read
/// LaunchServices and change nothing on the host.
@Suite(.serialized)
struct WorkspaceBlockingSeamTests {
    #if DEBUG || CMUX_BLOCKING_CHECKS
    @MainActor @Test func eachWorkspaceSeamOnTheMainThreadRecordsOneSiteAtItsCaller() async {
        let table = BlockingViolationTable(mode: .record)
        let expected = BlockingViolationTable.$scoped.withValue(table) { callEachWorkspaceSeam() }
        await table.flush()

        #expect(expected.count == 7)
        #expect(Set(expected.map(\.location)).count == expected.count)
        #expect(BlockingDetector(table: table).sites == expected)
    }

    @MainActor @Test func theSameWorkspaceSeamsOnANamedSerialQueueRecordNothing() async {
        let table = BlockingViolationTable(mode: .record)
        let (onMain, called) = await callEachWorkspaceSeamOnNamedQueue(table)
        await table.flush()

        #expect(!onMain)
        #expect(called == 7)
        #expect(BlockingDetector(table: table).sites.isEmpty)
    }
    #endif
}

#if DEBUG || CMUX_BLOCKING_CHECKS
/// Calls every NSWorkspace seam once, on the caller's thread, and returns the site each call records on the
/// main thread (its kind and this file's line of the call).
private nonisolated func callEachWorkspaceSeam() -> [BlockingSite] {
    var expected: [BlockingSite] = []
    func seam(_ kind: BlockingKind, fileID: StaticString = #fileID, line: UInt = #line, _ call: () -> Void) {
        expected.append(BlockingSite(kind: kind, location: "\(fileID):\(line)", count: 1))
        call()
    }

    let workspace = NSWorkspace.shared
    let hosts = URL(fileURLWithPath: "/etc/hosts")
    seam(.systemCall) { _ = workspace.blockingURLForApplication(withBundleIdentifier: "com.apple.finder") }
    seam(.systemCall) { _ = workspace.blockingURLForApplication(toOpen: hosts) }
    seam(.systemCall) { _ = workspace.blockingURLForApplication(toOpen: UTType.plainText) }
    seam(.systemCall) { _ = workspace.blockingURLsForApplications(toOpen: hosts) }
    seam(.systemCall) { _ = workspace.blockingURLsForApplications(toOpen: UTType.plainText) }
    seam(.systemCall) { _ = workspace.blockingIcon(forFile: hosts.path) }
    seam(.systemCall) { _ = workspace.blockingIcon(for: UTType.plainText) }
    return expected
}

/// The same calls on a named serial queue, a context where blocking is allowed (not the cooperative pool
/// or a GCD root queue), with `table` bound there. Returns whether they ran on the main thread and how many
/// seams they called.
private nonisolated func callEachWorkspaceSeamOnNamedQueue(_ table: BlockingViolationTable) async -> (Bool, Int) {
    let queue = DispatchQueue(label: "com.cmuxterm.tests.blocking-workspace-seams")
    return await withCheckedContinuation { continuation in
        queue.async {
            continuation.resume(returning: BlockingViolationTable.$scoped.withValue(table) {
                (pthread_main_np() != 0, callEachWorkspaceSeam().count)
            })
        }
    }
}
#endif
