import CmuxNextBrowser
import Foundation
import Testing

/// A Cmd-click in a Cloud VM terminal names a path on the VM (#25581). The path is tidied as text:
/// `.` and `..` folded, nothing of this Mac read. `NSString.standardizingPath` consults this Mac's
/// file system: it drops `/private` when the shorter path exists HERE (`/private/etc/hosts` became
/// `/etc/hosts`), and its documentation resolves `..` through this Mac's symlinks, so a VM path could
/// become another path, decided by this Mac's disk.
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

    @Test func aPathThatAlsoExistsOnThisMacKeepsItsPrivatePrefix() {
        // /etc/hosts exists on every Mac, so standardizingPath shortened these after a lookup here.
        #expect(TerminalLinkResolver().remoteCandidates("/private/etc/hosts", cwd: nil) == ["/private/etc/hosts"])
        #expect(TerminalLinkResolver().remoteCandidates("hosts:3", cwd: "/private/etc") == ["/private/etc/hosts"])
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
