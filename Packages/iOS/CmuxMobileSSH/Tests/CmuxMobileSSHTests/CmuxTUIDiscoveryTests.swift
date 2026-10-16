@testable import CmuxMobileSSH
import Foundation
import Testing

/// Session socket discovery (PRD D34) against listings shaped like the
/// server's path resolution (`spec/transports.md`, Unix Socket).
@Suite struct CmuxTUIDiscoveryTests {
    /// A session name too long for a socket path lives at
    /// `cmux-tui-hashed-<uid>/<sha256>.sock`.
    static let longName = String(repeating: "a-very-long-cmux-tui-session-name-", count: 4)

    @Test func digestIsTheFullLowercaseSHA256OfTheName() {
        // SHA-256("abc"), FIPS 180-2 test vector.
        #expect(CmuxTUISessionSocket.digest(of: "abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func hashedSocketsAreListedAndMatchedByDigest() {
        let digest = CmuxTUISessionSocket.digest(of: Self.longName)
        let output = """
        /run/user/501/cmux-tui-501/main.sock
        /run/user/501/cmux-tui-hashed-501/\(digest).sock
        /tmp/cmux-tui-hashed-501/\(digest).sock
        /tmp/cmux-tui-hashed-501/not-a-digest.sock
        /tmp/cmux-tui-hashed-501/\(digest.uppercased()).sock
        """
        let sockets = CmuxTUIRemote.parseSessionSockets(output)
        #expect(sockets.count == 2)
        let hashed = sockets.last
        #expect(hashed?.name == nil)
        #expect(hashed?.digest == digest)
        // The first runtime directory wins for a hashed session too.
        #expect(hashed?.path == "/run/user/501/cmux-tui-hashed-501/\(digest).sock")
        #expect(hashed?.serves(session: Self.longName) == true)
        #expect(hashed?.serves(session: "main") == false)
        #expect(sockets.first?.serves(session: "main") == true)
    }

    /// A named socket with a digest-like name is still a named socket: only
    /// the hashed directory holds hashed sockets.
    @Test func digestNamesOutsideTheHashedDirectoryAreSessionNames() {
        let digest = CmuxTUISessionSocket.digest(of: "x")
        let sockets = CmuxTUIRemote.parseSessionSockets("/tmp/cmux-tui-501/\(digest).sock\n")
        #expect(sockets.map(\.name) == [digest])
    }

    /// Names the server accepts are listed: spaces, Unicode, long text.
    /// Separators and control characters are not session names.
    @Test func socketSessionNamesFollowTheServerRule() {
        for valid in ["main", "my work", "日本語", ":colon", Self.longName] {
            #expect((try? CmuxTUIRemote.validateSocketSession(valid)) != nil, "\(valid)")
        }
        for invalid in ["", ".", "..", "a\\b", "a\u{1B}b", "a\u{2028}b", "a\u{0085}b"] {
            #expect((try? CmuxTUIRemote.validateSocketSession(invalid)) == nil, "\(invalid.debugDescription)")
        }
        let sockets = CmuxTUIRemote.parseSessionSockets("/tmp/cmux-tui-501/my work.sock\n")
        #expect(sockets.map(\.name) == ["my work"])
    }
}
