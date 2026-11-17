@testable import CmuxNextPages
import Darwin
import Foundation
import Testing

/// A page file's bytes are read off the main actor, so handing the reply body to WebKit or CEF on
/// the main actor copies memory and touches no disk. Base red: ``PageSchemeHandler/read(_:)`` used
/// `Data(contentsOf:options: .mappedIfSafe)`, a mapping that reads nothing; the pages faulted in on
/// the main thread when `-[WKURLSchemeTaskImpl didReceiveData:]` copied the body into WebKit's
/// shared memory (Leo's NIGHTLY hang 2026-11-16T21-27-58, build 6f62dcd: main thread in
/// `_platform_memmove` under `WebURLSchemeTask::didReceiveData`, 0.021 s CPU of 2.248 s, 234 page-ins).
///
/// The oracle: a body that was read holds the file as it was at reply time, so a later in-place
/// write to the file does not show through it. A mapped body is the file's pages, and does.
@MainActor
struct PageFileReadOffMainTests {
    private static let size = 20 << 20

    @Test func theReplyBodyHoldsTheBytesReadNotAMappingOfTheFile() async throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "big.bin")
        try Data(repeating: 0x41, count: Self.size).write(to: file)
        let handler = PageSchemeHandler(page: .markdown, root: root, devServer: nil)
        handler.liveOverride = { WebDevOverride() }
        let url = try #require(URL(string: PageDescriptor.markdown.origin + "/big.bin"))
        let reply = try #require(await handler.reply(to: url))
        #expect(reply.body.count == Self.size)

        // What WebKit's copy into its IPC buffer costs on the main actor (reported, not asserted).
        let cost = Self.mainActorCopyCost(reply.body)
        print("page-read-off-main: main-actor copy of a \(Self.size >> 20) MiB reply body: "
            + "\(String(format: "%.3f", cost.milliseconds)) ms, \(cost.faults) page faults (\(cost.pageIns) page-ins)")

        try Self.overwriteInPlace(file, with: 0x42)
        #expect(reply.body == Data(repeating: 0x41, count: Self.size),
                "the reply body changed with the file: it is a mapping, so its pages fault in on the main thread")
    }

    // MARK: - Helpers

    /// Wall time, page faults and page-ins of copying `body` into an already touched buffer, as
    /// `SharedMemory::copyBuffer` does.
    static func mainActorCopyCost(_ body: Data) -> (milliseconds: Double, faults: Int, pageIns: Int) {
        let destination = UnsafeMutableRawBufferPointer.allocate(byteCount: body.count, alignment: 16)
        defer { destination.deallocate() }
        memset(destination.baseAddress, 0, body.count) // fault the destination in first; only the source counts
        var before = rusage(), after = rusage()
        getrusage(RUSAGE_SELF, &before)
        let start = ContinuousClock.now
        body.withUnsafeBytes { source in destination.copyMemory(from: source) }
        let elapsed = ContinuousClock.now - start
        getrusage(RUSAGE_SELF, &after)
        let milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        return (milliseconds, Int(after.ru_minflt - before.ru_minflt) + Int(after.ru_majflt - before.ru_majflt),
                Int(after.ru_majflt - before.ru_majflt))
    }

    /// Writes `byte` over every byte of `file`, in place (same inode, same length).
    static func overwriteInPlace(_ file: URL, with byte: UInt8) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(repeating: byte, count: size))
        try handle.synchronize()
    }

    static func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "page-read-off-main-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.resolvingSymlinksInPath()
    }
}
