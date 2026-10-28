import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextChromiumRuntime

/// p02-threads-053 (plans/cmux-next/chrome-parity/p02-threads.md, maybe-main-blocking): a pack item's code-signature
/// check hashes every file of the item and waits on the Security daemons, so it runs on the app's system lane, never
/// on the thread of the installer that awaits it (Chrome posts such work with `base::MayBlock`), at the install
/// job's priority. A check that never ran is ``ChromiumRuntimeInstallError/cancelled``, not a signature failure.
@Suite(.timeLimit(.minutes(1))) struct SignatureCheckLaneTests {
    @Test func anUnsignedItemIsRefusedOnTheSystemLane() async throws {
        let folder = try TemporaryFolder()
        let item = try Self.unsignedItem(in: folder, named: "libunsigned.dylib")
        let (lanes, ran) = AsyncStream.makeStream(of: BlockingLane.self)
        let work = BackgroundWork(label: "test.signature-check", onRan: { lane, _, _, _ in ran.yield(lane) })

        await #expect(throws: ChromiumRuntimeInstallError.signature("libunsigned.dylib")) {
            try await SecCodeChromiumRuntimeSignatureChecker(work: work, isValid: Self.refuses).check(item, teamID: "ABCDE12345", priority: .user)
        }

        var first = lanes.makeAsyncIterator()
        #expect(await first.next() == .system, "the Security calls did not run on the system lane")
    }

    /// The same unsigned item gives `.signature` when its check runs (above), so `.cancelled` here proves it never ran.
    @Test func aCheckThatQuitDroppedIsCancelledNotASignatureFailure() async throws {
        let folder = try TemporaryFolder()
        let item = try Self.unsignedItem(in: folder, named: "libdropped.dylib")
        let work = BackgroundWork(label: "test.signature-shutdown")
        work.beginShutdown()

        await #expect(throws: ChromiumRuntimeInstallError.cancelled) {
            try await SecCodeChromiumRuntimeSignatureChecker(work: work, isValid: Self.refuses).check(item, teamID: "ABCDE12345", priority: .user)
        }
    }

    @Test func aCheckWhoseCallerIsCancelledIsCancelledNotASignatureFailure() async throws {
        let folder = try TemporaryFolder()
        let item = try Self.unsignedItem(in: folder, named: "libcancelled.dylib")
        let checker = SecCodeChromiumRuntimeSignatureChecker(work: BackgroundWork(label: "test.signature-cancel"), isValid: Self.refuses)
        let check = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await checker.check(item, teamID: "ABCDE12345", priority: .user)
        }
        await #expect(throws: ChromiumRuntimeInstallError.cancelled) { try await check.value }
    }

    /// A background prefetch's check, from a best-effort job task, runs at best effort; a person's at user-visible.
    @Test func aPrefetchChecksAtBestEffort() async throws {
        #expect(SecCodeChromiumRuntimeSignatureChecker.lanePriority(.background) == .bestEffort)
        #expect(SecCodeChromiumRuntimeSignatureChecker.lanePriority(.user) == .userVisible)

        let folder = try TemporaryFolder()
        let item = try Self.unsignedItem(in: folder, named: "libprefetch.dylib")
        let (runs, ran) = AsyncStream.makeStream(of: WorkPriority.self)
        let work = BackgroundWork(label: "test.signature-priority", onRan: { _, priority, _, _ in ran.yield(priority) })
        let checker = SecCodeChromiumRuntimeSignatureChecker(work: work, isValid: Self.refuses)
        // Detached and not awaited until the item ran: awaiting it would escalate it to the test's priority.
        let check = Task.detached(priority: WorkPriority.bestEffort.taskPriority) {
            try? await checker.check(item, teamID: "ABCDE12345", priority: .background)
        }
        var first = runs.makeAsyncIterator()
        #expect(await first.next() == .bestEffort)
        _ = await check.value
    }

    /// The injected check for an unsigned item: it is never valid.
    private static let refuses: SecCodeChromiumRuntimeSignatureChecker.Validity = { _, _, _ in false }

    private static func unsignedItem(in folder: TemporaryFolder, named name: String) throws -> URL {
        let item = folder.url.appending(path: name)
        try Data("not code".utf8).write(to: item)
        return item
    }
}
