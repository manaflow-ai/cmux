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
/// The oracle asks the kernel: the reply body's memory must not be backed by the file
/// (`proc_regionfilename`). The file sits where a plain `.mappedIfSafe` read is first shown to
/// map (a read-only file, as in the signed app bundle), so the oracle can tell a read from a map.
@MainActor
struct PageFileReadOffMainTests {
    @Test func theReplyBodyIsReadNotAMappingOfTheFile() async throws {
        let (root, file) = try MappedReadOracle.mappableFile(named: "big.bin", prefix: "page-read-off-main")
        defer { MappedReadOracle.remove(root) }
        let handler = PageSchemeHandler(page: .markdown, root: root, devServer: nil)
        handler.liveOverride = { WebDevOverride() }
        let url = try #require(URL(string: PageDescriptor.markdown.origin + "/big.bin"))
        let reply = try #require(await handler.reply(to: url))
        #expect(reply.body.count == MappedReadOracle.size)

        // What WebKit's copy into its IPC buffer costs on the main actor (reported, not asserted).
        let cost = MappedReadOracle.copyCost(reply.body)
        print("page-read-off-main: main-actor copy of a \(MappedReadOracle.size >> 20) MiB reply body: "
            + "\(String(format: "%.3f", cost.milliseconds)) ms, \(cost.faults) page faults (\(cost.pageIns) page-ins)")

        let backing = MappedReadOracle.backingFile(of: reply.body)
        #expect(backing == nil, "the reply body is a mapping of \(backing ?? ""): its pages fault in on the main thread")
        #expect(reply.body == Data(repeating: 0x41, count: MappedReadOracle.size))
    }
}

/// Tells a read from a mapping, and finds a file `.mappedIfSafe` really maps.
enum MappedReadOracle {
    static let size = 20 << 20

    /// The file whose pages back `data`'s bytes, nil for anonymous (read) memory.
    static func backingFile(of data: Data) -> String? {
        data.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let length = proc_regionfilename(getpid(), UInt64(UInt(bitPattern: base)), &path, UInt32(path.count))
            return length > 0 ? String(cString: path) : nil
        }
    }

    /// A new directory holding `name` (`size` bytes of 0x41), where a plain `.mappedIfSafe` read of
    /// it is proven to map. Each candidate place and file mode is tried and reported.
    static func mappableFile(named name: String, prefix: String) throws -> (directory: URL, file: URL) {
        let bases = [URL(fileURLWithPath: "/private/tmp", isDirectory: true),
                     FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches", directoryHint: .isDirectory),
                     FileManager.default.temporaryDirectory]
        for base in bases {
            for readOnly in [true, false] {
                let dir = base.appending(path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory).resolvingSymlinksInPath()
                guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { continue }
                let file = dir.appending(path: name)
                do {
                    try Data(repeating: 0x41, count: size).write(to: file)
                    if readOnly { try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path) }
                    let control = try Data(contentsOf: file, options: .mappedIfSafe)
                    let backing = backingFile(of: control)
                    print("\(prefix): control .mappedIfSafe in \(base.path) (\(readOnly ? "read-only" : "writable")): "
                        + (backing.map { "mapped from \($0)" } ?? "read, not mapped"))
                    if backing != nil {
                        let cost = copyCost(control)
                        print("\(prefix): control, main-actor copy of a mapped \(size >> 20) MiB body: "
                            + "\(String(format: "%.3f", cost.milliseconds)) ms, \(cost.faults) page faults (\(cost.pageIns) page-ins)")
                        return (dir, file)
                    }
                } catch {
                    print("\(prefix): control in \(base.path) failed: \(error)")
                }
                remove(dir)
            }
        }
        Issue.record("no candidate file is mapped by .mappedIfSafe here: the oracle cannot tell a read from a map")
        throw CocoaError(.fileReadUnknown)
    }

    static func remove(_ dir: URL) {
        if let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for name in names { _ = chmod(dir.appending(path: name).path, 0o644) }
        }
        try? FileManager.default.removeItem(at: dir)
    }

    /// Wall time, page faults and page-ins of copying `body` into an already touched buffer, as
    /// `SharedMemory::copyBuffer` does.
    static func copyCost(_ body: Data) -> (milliseconds: Double, faults: Int, pageIns: Int) {
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
}
