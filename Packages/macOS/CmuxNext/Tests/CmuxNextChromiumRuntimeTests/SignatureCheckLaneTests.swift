import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextChromiumRuntime

/// p02-threads-053 (plans/cmux-next/chrome-parity/p02-threads.md, maybe-main-blocking): a pack item's code-signature
/// check hashes every file of the item and waits on the Security daemons, so it runs on the app's system lane, never
/// on the thread of the installer that awaits it (Chrome posts such work with `base::MayBlock()`).
@Suite(.timeLimit(.minutes(1))) struct SignatureCheckLaneTests {
    @Test func anUnsignedItemIsRefusedOnTheSystemLane() async throws {
        let folder = try TemporaryFolder()
        let item = folder.url.appending(path: "libunsigned.dylib")
        try Data("not code".utf8).write(to: item)
        let (lanes, ran) = AsyncStream.makeStream(of: BlockingLane.self)
        let work = BackgroundWork(label: "test.signature-check", onRan: { lane, _, _, _ in ran.yield(lane) })

        await #expect(throws: ChromiumRuntimeInstallError.signature("libunsigned.dylib")) {
            try await SecCodeChromiumRuntimeSignatureChecker(work: work).check(item, teamID: "ABCDE12345")
        }

        var first = lanes.makeAsyncIterator()
        #expect(await first.next() == .system, "the Security calls did not run on the system lane")
    }

    @Test func aCheckWhoseCallerIsCancelledVouchesForNothing() async throws {
        let folder = try TemporaryFolder()
        let item = folder.url.appending(path: "libcancelled.dylib")
        try Data("not code".utf8).write(to: item)
        let checker = SecCodeChromiumRuntimeSignatureChecker(work: BackgroundWork(label: "test.signature-cancel"))
        let check = Task { try await checker.check(item, teamID: "ABCDE12345") }
        check.cancel()
        await #expect(throws: ChromiumRuntimeInstallError.signature("libcancelled.dylib")) { try await check.value }
    }
}
