import CmuxTerminalCore
import Foundation
import Testing

@Suite struct RemoteTerminalPathResolverTests {
    private let resolver = RemoteTerminalPathResolver()

    @Test func tildeUsesRemoteHomeAndNeverTheMacHome() {
        #expect(resolver.candidates(
            tokens: ["~/notes.md"], workingDirectory: "/work", homeDirectory: "/srv/ssh-user", remoteHost: "host"
        ) == ["/srv/ssh-user/notes.md"])
        #expect(resolver.candidates(
            tokens: ["~/notes.md", "relative.txt"], workingDirectory: nil, homeDirectory: nil, remoteHost: "host"
        ).isEmpty)
    }

    @Test func resolvesSourceDirectoryWithoutCollapsingRemoteSymlinks() {
        #expect(resolver.candidates(
            tokens: ["linked/../notes.txt"], workingDirectory: "/remote/project", homeDirectory: nil, remoteHost: "host"
        ) == ["/remote/project/linked/../notes.txt"])
    }

    @Test func absolutePathsDoNotRequireDirectoryReports() {
        #expect(resolver.candidates(
            tokens: ["/remote/notes.txt"], workingDirectory: nil, homeDirectory: nil, remoteHost: "host"
        ) == ["/remote/notes.txt"])
    }

    @Test func fileURLsDecodeSpacesAndValidateTheRemoteHost() {
        #expect(resolver.candidates(
            tokens: ["file://host/remote/file%20name.txt"], workingDirectory: nil, homeDirectory: nil, remoteHost: "host"
        ) == ["/remote/file name.txt"])
        #expect(resolver.candidates(
            tokens: ["file://other/remote/notes.txt", "https://host/notes.txt"],
            workingDirectory: "/remote", homeDirectory: nil, remoteHost: "host"
        ).isEmpty)
    }

    @Test func literalPunctuationPrecedesTrimmedAndUnescapedCandidates() {
        let paths = resolver.candidates(
            tokens: ["notes\\ file.txt,"], workingDirectory: "/remote", homeDirectory: nil, remoteHost: "host"
        )
        #expect(paths.first == "/remote/notes\\ file.txt,")
        #expect(paths.contains("/remote/notes file.txt"))
        #expect(Set(paths).count == paths.count)
    }

    @Test func visibleColumnsKeepTheFullSpacedFilename() {
        let tokens = resolver.tokens(in: "alpha.txt  remote file.txt  omega.txt", column: 16)
        let paths = resolver.candidates(
            tokens: tokens, workingDirectory: "/remote", homeDirectory: nil, remoteHost: "host"
        )
        #expect(paths.first == "/remote/remote file.txt")
        #expect(!paths.contains("/remote/omega.txt"))
    }

    @Test func refusesNamedUserTildesAndControlCharacters() {
        #expect(resolver.candidates(
            tokens: ["~other/file.txt", "/remote/a\0b", "/remote/a\nb"],
            workingDirectory: "/remote", homeDirectory: "/home/user", remoteHost: "host"
        ).isEmpty)
    }
}
