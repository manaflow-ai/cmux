import Foundation
import Testing
@testable import CmuxDockExtensions

@Suite("DockExtensionSource")
struct DockExtensionSourceTests {
    @Test func parsesShorthandForms() {
        #expect(
            DockExtensionSource.parseGitHub("owner/repo")
                == .github(owner: "owner", repository: "repo", subdirectory: nil)
        )
        #expect(
            DockExtensionSource.parseGitHub("owner/repo/sub/dir")
                == .github(owner: "owner", repository: "repo", subdirectory: "sub/dir")
        )
        #expect(
            DockExtensionSource.parseGitHub("  owner/repo.git ")
                == .github(owner: "owner", repository: "repo", subdirectory: nil)
        )
    }

    @Test func parsesGitHubURLs() {
        #expect(
            DockExtensionSource.parseGitHub("https://github.com/manaflow-ai/cmux")
                == .github(owner: "manaflow-ai", repository: "cmux", subdirectory: nil)
        )
        #expect(
            DockExtensionSource.parseGitHub("https://github.com/o/r.git")
                == .github(owner: "o", repository: "r", subdirectory: nil)
        )
        #expect(
            DockExtensionSource.parseGitHub("github.com/o/r/examples/tui")
                == .github(owner: "o", repository: "r", subdirectory: "examples/tui")
        )
    }

    @Test func rejectsInvalidSources() {
        for input in ["", "justone", "owner//repo", "ow ner/repo", "o/r/../x", "o/r/."] {
            #expect(DockExtensionSource.parseGitHub(input) == nil, "should reject \(input)")
        }
    }

    @Test func derivedURLs() {
        let source = DockExtensionSource.github(owner: "o", repository: "r", subdirectory: "sub")
        #expect(source.cloneURLString == "https://github.com/o/r.git")
        #expect(source.webURL == URL(string: "https://github.com/o/r"))
        #expect(source.description == "o/r/sub")
        #expect(source.subdirectory == "sub")
        #expect(!source.isLocal)
        #expect(DockExtensionSource.local(path: "/x").isLocal)
    }

    @Test func codableRoundTripsBothCases() throws {
        let cases: [DockExtensionSource] = [
            .github(owner: "o", repository: "r", subdirectory: nil),
            .github(owner: "o", repository: "r", subdirectory: "a/b"),
            .local(path: "/Users/dev/my-ext"),
        ]
        for source in cases {
            let encoded = try JSONEncoder().encode([source])
            let decoded = try JSONDecoder().decode([DockExtensionSource].self, from: encoded)
            #expect(decoded == [source])
        }
        // GitHub sources encode as the plain shorthand string.
        let encoded = try JSONEncoder().encode([DockExtensionSource.github(owner: "o", repository: "r", subdirectory: "s")])
        #expect(String(decoding: encoded, as: UTF8.self) == "[\"o\\/r\\/s\"]"
            || String(decoding: encoded, as: UTF8.self) == "[\"o/r/s\"]")
    }
}
