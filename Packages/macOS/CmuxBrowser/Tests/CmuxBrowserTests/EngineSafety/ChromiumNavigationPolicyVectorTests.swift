import CmuxBrowser
import Foundation
import Testing

/// The shared policy vectors under `schemas/`: the Swift rules here and the
/// CEF shim's C++ copies read the same files.
private enum PolicyVectors {
    static func load<Case: Decodable>(_ path: String, as _: Case.Type) -> [Case] {
        var root = URL(fileURLWithPath: #filePath)
        // Tests/CmuxBrowserTests/EngineSafety/<file> -> repository root.
        for _ in 0..<7 { root.deleteLastPathComponent() }
        let data = try! Data(contentsOf: root.appendingPathComponent(path))
        return try! JSONDecoder().decode(Corpus<Case>.self, from: data).cases
    }

    struct Corpus<Case: Decodable>: Decodable {
        let cases: [Case]
    }
}

struct AgentURLCase: Decodable, CustomTestStringConvertible, Sendable {
    let url: String
    let refused: Bool
    var testDescription: String { url.debugDescription }
}

struct LocalFileHandoffCase: Decodable, CustomTestStringConvertible, Sendable {
    let url: String
    let cef: Bool
    var testDescription: String { url.debugDescription }
}

@Suite struct ChromiumNavigationPolicyVectorTests {
    static let agentCases = PolicyVectors.load("schemas/agent-url-policy/vectors.json", as: AgentURLCase.self)
    static let handoffCases = PolicyVectors.load("schemas/local-file-handoff/vectors.json", as: LocalFileHandoffCase.self)

    @Test func vectorsAreNotEmpty() {
        #expect(Self.agentCases.count > 20)
        #expect(Self.handoffCases.count > 5)
    }

    @Test(arguments: agentCases)
    func agentURLPolicy(_ vector: AgentURLCase) {
        #expect(BrowserAgentURLPolicy.refuses(vector.url) == vector.refused)
    }

    @Test(arguments: handoffCases)
    func chromiumLocalFileHandoff(_ vector: LocalFileHandoffCase) throws {
        let url = try #require(URL(string: vector.url))
        #expect((BrowserLocalFileHandoff.chromiumHandoff(for: url) != nil) == vector.cef)
    }

    @Test func handoffDestinations() throws {
        #expect(BrowserLocalFileHandoff.chromiumHandoff(for: try #require(URL(string: "file:///a/b.md"))) == .markdownViewer)
        #expect(BrowserLocalFileHandoff.chromiumHandoff(for: try #require(URL(string: "file:///a/b.mp4"))) == .webKitPane)
        #expect(BrowserLocalFileHandoff.chromiumHandoff(for: try #require(URL(string: "https://x.test/b.mp4"))) == nil)
    }

    @Test func externalAppSchemes() {
        #expect(ChromiumExternalAppURL.isExternal("mailto:a@b.test"))
        #expect(ChromiumExternalAppURL.isExternal("TEL:+1555"))
        #expect(ChromiumExternalAppURL.isExternal("vscode://file/x"))
        #expect(!ChromiumExternalAppURL.isExternal("https://example.com"))
        #expect(!ChromiumExternalAppURL.isExternal("chrome://settings"))
        #expect(!ChromiumExternalAppURL.isExternal("web+mastodon://share"))
        #expect(!ChromiumExternalAppURL.isExternal("ext+foo:bar"))
        #expect(!ChromiumExternalAppURL.isExternal("no-colon"))
        #expect(!ChromiumExternalAppURL.isExternal(":leading"))
    }
}
