@testable import CmuxNextPages
import Darwin
import Foundation
import Testing

/// A page file's bytes are read off the main actor, so handing the reply body to WebKit or CEF on
/// the main actor copies memory and touches no disk. Base red: ``PageSchemeHandler/read(_:)`` used
/// `Data(contentsOf:options: .mappedIfSafe)`, a mapping that reads nothing; the pages faulted in on
/// the main thread when `-[WKURLSchemeTaskImpl didReceiveData:]` copied the body into WebKit's
/// shared memory (NIGHTLY hang 2026-11-16T21-27-58, build 6f62dcd: main thread in
/// `_platform_memmove` under `WebURLSchemeTask::didReceiveData`, 0.021 s CPU of 2.248 s, 234 page-ins).
///
/// The oracle: a body that was read holds the file as it was at reply time, so a later in-place
/// write to the file does not show through it. A mapped body is the file's pages, and does.
@MainActor
struct PageFileReadOffMainTests {
    static let size = 20 << 20

    @Test func theReplyBodyHoldsTheBytesReadNotAMappingOfTheFile() async throws {
        let root = try Self.mappableDirectory()
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

    /// A new directory on a volume where `.mappedIfSafe` really maps, as it does for the app's
    /// bundle on the boot disk. Foundation reads instead of mapping on a volume it deems unsafe
    /// (a CI worker's `TMPDIR` may sit on an external scratch volume), where a mapped read would
    /// pass this oracle unseen; so the control below proves the directory shows a mapping first.
    static func mappableDirectory() throws -> URL {
        let candidates = [URL(fileURLWithPath: "/private/tmp", isDirectory: true),
                          FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches", directoryHint: .isDirectory),
                          FileManager.default.temporaryDirectory]
        for base in candidates {
            let dir = base.appending(path: "page-read-off-main-\(UUID().uuidString)", directoryHint: .isDirectory)
            guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { continue }
            let dirReal = dir.resolvingSymlinksInPath()
            if (try? showsMapping(in: dirReal)) == true { return dirReal }
            try? FileManager.default.removeItem(at: dirReal)
        }
        Issue.record("no candidate directory shows a .mappedIfSafe mapping: the oracle cannot tell a read from a map here")
        throw CocoaError(.fileReadUnknown)
    }

    /// The control: a plain `.mappedIfSafe` read of a file in `dir` changes with an in-place write.
    private static func showsMapping(in dir: URL) throws -> Bool {
        let probe = dir.appending(path: "probe.bin")
        defer { try? FileManager.default.removeItem(at: probe) }
        try Data(repeating: 0x41, count: size).write(to: probe)
        let mapped = try Data(contentsOf: probe, options: .mappedIfSafe)
        let cost = mainActorCopyCost(mapped)
        try overwriteInPlace(probe, with: 0x42)
        let shows = mapped.last == 0x42
        if shows {
            print("page-read-off-main: control, main-actor copy of a mapped \(size >> 20) MiB body in \(dir.deletingLastPathComponent().path): "
                + "\(String(format: "%.3f", cost.milliseconds)) ms, \(cost.faults) page faults (\(cost.pageIns) page-ins)")
        }
        return shows
    }

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
}
