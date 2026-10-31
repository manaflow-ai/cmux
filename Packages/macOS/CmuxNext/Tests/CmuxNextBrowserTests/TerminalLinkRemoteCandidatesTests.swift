import CmuxNextBrowser
import Foundation
import Testing

/// A Cmd-click in a Cloud VM terminal names a path on the VM (#25581). The path is tidied as text:
/// `.` and `..` folded, nothing of this Mac read. `NSString.standardizingPath` resolved `..` through
/// this Mac's symlinks and dropped `/private`, so a VM path could become a path of this Mac's disk.
@Suite struct TerminalLinkRemoteCandidatesTests {
    @Test func dotDotFoldsAsTextEvenWhereThisMacHasASymlink() throws {
        // A symlink on this Mac at the same path the VM's terminal names: `link` -> `real`.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("remote-candidates-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real/sub")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("real"))
        let link = root.path + "/link"

        #expect(TerminalLinkResolver().remoteCandidates("../notes.md", cwd: link + "/sub") == [link + "/notes.md"])
        #expect(TerminalLinkResolver().remoteCandidates(link + "/sub/../notes.md", cwd: nil) == [link + "/notes.md"])
    }

    @Test func privateStaysInAVMPath() {
        #expect(TerminalLinkResolver().remoteCandidates("/private/var/tmp/../log/x.md", cwd: nil) == ["/private/var/log/x.md"])
        #expect(TerminalLinkResolver().remoteCandidates("x.md", cwd: "/private/tmp/./a") == ["/private/tmp/a/x.md"])
    }

    @Test func dotDotNeverLeavesTheRoot() {
        #expect(TerminalLinkResolver().remoteCandidates("../../x.md", cwd: "/home") == ["/x.md"])
        #expect(TerminalLinkResolver().remoteCandidates("/a//b/./c/", cwd: nil) == ["/a/b/c"])
    }
}
