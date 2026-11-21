import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The app writes the same canonical JSON bytes as the daemon and acpmux: the golden cases Rust
/// checks (`cmux-conversation/tests/fixtures/canonical_json.json`, escapes, Unicode and key byte
/// order), so a Home answer's request digest and answers proof agree on every byte.
@Suite struct CanonicalJSONFixtureTests {
    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // CmuxNextAgentPaneTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // CmuxNext
        .deletingLastPathComponent() // macOS
        .deletingLastPathComponent() // Packages
        .appendingPathComponent("cmux-tui/crates/cmux-conversation/tests/fixtures/canonical_json.json")

    @Test func everyGoldenCaseHasTheSameBytesAndDigest() throws {
        let data = try Data(contentsOf: Self.fixture)
        let root = try #require(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any])
        let cases = try #require(root["cases"] as? [[String: Any]])
        #expect(cases.count >= 5)
        for golden in cases {
            let name = golden["name"] as? String ?? "?"
            let value = try #require(golden["value"])
            #expect(AcpmuxSecretKey.canonicalJSON(value) == golden["canonical"] as? String, "\(name)")
            #expect(AcpmuxSecretKey.canonicalDigest(value) == golden["sha256"] as? String, "\(name)")
        }
    }
}
