@testable import CmuxNextAgentPane
import Darwin
import Foundation
import Testing

/// The agent pane's bundled files are read off the main actor: the body handed to
/// `WKURLSchemeTask.didReceive(_:)` on the main actor is bytes, not a mapping whose pages fault in
/// there (the same class as the NIGHTLY hang 2026-11-16T21-27-58 in `PageSchemeHandler`). Base
/// red: ``AgentPaneSchemeHandler/read(_:)`` mapped the file. The oracle asks the kernel whether
/// the body's memory is backed by the file, for a file a plain `.mappedIfSafe` read is first
/// shown to map (read-only, as in the signed app bundle).
struct AgentPaneFileReadOffMainTests {
    static let size = 20 << 20

    @Test func theReadBodyIsReadNotAMappingOfTheFile() async throws {
        let (dir, file) = try Self.mappableFile()
        defer { Self.remove(dir) }
        let body = try #require(await AgentPaneSchemeHandler.read(file))
        #expect(body.count == Self.size)
        let backing = Self.backingFile(of: body)
        #expect(backing == nil, "the body is a mapping of \(backing ?? ""): its pages fault in on the main thread")
    }

    static func backingFile(of data: Data) -> String? {
        data.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let length = proc_regionfilename(getpid(), UInt64(UInt(bitPattern: base)), &path, UInt32(path.count))
            return length > 0 ? String(cString: path) : nil
        }
    }

    static func mappableFile() throws -> (URL, URL) {
        let bases = [URL(fileURLWithPath: "/private/tmp", isDirectory: true),
                     FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches", directoryHint: .isDirectory),
                     FileManager.default.temporaryDirectory]
        for base in bases {
            for readOnly in [true, false] {
                let dir = base.appending(path: "agent-pane-read-off-main-\(UUID().uuidString)", directoryHint: .isDirectory)
                guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { continue }
                let file = dir.appending(path: "big.bin")
                if (try? Data(repeating: 0x41, count: size).write(to: file)) != nil,
                   !readOnly || (try? FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)) != nil,
                   let control = try? Data(contentsOf: file, options: .mappedIfSafe), backingFile(of: control) != nil {
                    return (dir, file)
                }
                remove(dir)
            }
        }
        Issue.record("no candidate file is mapped by .mappedIfSafe here: the oracle cannot tell a read from a map")
        throw CocoaError(.fileReadUnknown)
    }

    static func remove(_ dir: URL) {
        _ = chmod(dir.appending(path: "big.bin").path, 0o644)
        try? FileManager.default.removeItem(at: dir)
    }
}
