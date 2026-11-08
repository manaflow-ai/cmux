import enum CmuxNextDaemon.DaemonError
import struct CmuxNextDaemon.FileSystemReadRequest
import struct CmuxNextDaemon.FileSystemReplaceRequest
import struct CmuxNextDaemon.FileSystemStatRequest
import protocol CmuxNextDaemonService.RemoteFileClient
import Foundation
import Testing

/// A Cloud chat's path chip opens nothing when the path reaches through a symlink on the machine
/// (``RemoteFileClient/reachesThroughLink(_:)``): the deny list reads the spelling only, and a link
/// such as `notes.md -> ~/.ssh/config` could name a secret.
@MainActor
struct CloudPathLinkCheckTests {
    /// Each path's kind as the daemon's `fs.stat` answers it (a link's own kind); a path not listed
    /// is outside the machine's roots and refused.
    final class Kinds: RemoteFileClient {
        var kinds: [String: String] = [:]
        var asked: [String] = []

        func stat(_ path: String) async throws -> FileSystemStatRequest.Response {
            asked.append(path)
            guard let kind = kinds[path] else { throw DaemonError.command(cmd: "fs", message: "outside", code: "fs.outside_roots") }
            return FileSystemStatRequest.Response(kind: kind, size: nil, revision: "1")
        }

        func read(_ path: String, maxBytes: Int) async throws -> FileSystemReadRequest.Response {
            throw DaemonError.notConnected
        }

        func replace(_ path: String, text: String, expected: String) async throws -> FileSystemReplaceRequest.Response {
            throw DaemonError.notConnected
        }
    }

    private static func machine() -> Kinds {
        let files = Kinds()
        files.kinds = ["/home/cmux": "directory", "/home/cmux/work": "directory", "/home/cmux/work/app": "directory",
                       "/home/cmux/work/app/README.md": "file", "/home/cmux/work/app/notes.md": "symlink",
                       "/home/cmux/work/app/linked": "symlink", "/home/cmux/work/app/linked/config": "file"]
        return files
    }

    @Test func aPlainFileReachesNoLink() async {
        let files = Self.machine()
        #expect(await !files.reachesThroughLink("/home/cmux/work/app/README.md"))
        // `/` and `/home` are outside the roots: their refused stats count as no link.
        #expect(files.asked == ["/home", "/home/cmux", "/home/cmux/work", "/home/cmux/work/app", "/home/cmux/work/app/README.md"])
    }

    @Test func aLinkedFileOrFolderReachesOne() async {
        let files = Self.machine()
        #expect(await files.reachesThroughLink("/home/cmux/work/app/notes.md"))
        #expect(await files.reachesThroughLink("/home/cmux/work/app/linked/config"))
    }
}
