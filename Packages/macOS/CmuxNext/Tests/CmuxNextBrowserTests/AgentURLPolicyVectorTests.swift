import Foundation
import Testing
@testable import CmuxNextBrowser

/// The shared vectors that the Swift, C++ (shim) and Rust (browser host)
/// copies of the agent URL rule all pass: schemas/agent-url-policy/vectors.json.
@Suite struct AgentURLPolicyVectorTests {
    struct Vectors: Decodable {
        struct Case: Decodable { let url: String; let refused: Bool }
        let cases: [Case]
    }

    static func vectors() throws -> Vectors {
        // Tests/CmuxNextBrowserTests/<file> -> repository root.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        let file = url.appending(path: "schemas/agent-url-policy/vectors.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: file))
    }

    @Test func everySharedVectorAgrees() throws {
        let vectors = try Self.vectors()
        #expect(!vectors.cases.isEmpty)
        for item in vectors.cases {
            #expect(AgentURLPolicy.refuses(item.url) == item.refused, "\(item.url.debugDescription)")
        }
    }

    /// More than two nested wrappers fail closed, as in the C++ copy.
    @Test func deepWrapperNestingIsRefused() {
        #expect(!AgentURLPolicy.refuses("blob:blob:https://a.test/x"))
        #expect(AgentURLPolicy.refuses("blob:blob:blob:https://a.test/x"))
        #expect(AgentURLPolicy.refuses("filesystem:blob:filesystem:https://a.test/"))
    }
}
