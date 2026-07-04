@testable import CmuxIssueInbox
import Foundation
import Testing

@Suite
struct IssueInboxConfigTests {
    @Test
    func decoderSkipsBadEntriesAndExpandsProjectRoot() throws {
        let decoder = IssueInboxConfigDecoder(homeDirectory: URL(fileURLWithPath: "/Users/tester"))
        let data = Data("""
        {
          "sources": [
            { "type": "github", "repo": "manaflow-ai/cmux", "projectRoot": "~/fun/cmuxterm-hq/repo", "ignored": true },
            { "type": "github" },
            { "repo": "missing/type" },
            { "type": "linear", "teamKey": "ENG", "projectRoot": "/tmp/project" },
            { "type": "jira", "project": "APP" }
          ],
          "autoRefreshSeconds": 30
        }
        """.utf8)

        let result = try decoder.decode(data)

        #expect(result.config.sources.count == 2)
        #expect(result.config.sources[0].sourceID == "github:manaflow-ai/cmux")
        #expect(result.config.sources[0].projectRoot == "/Users/tester/fun/cmuxterm-hq/repo")
        #expect(result.config.sources[1].sourceID == "linear:ENG")
        #expect(result.config.sources[1].apiKeyEnvVar == "LINEAR_API_KEY")
        #expect(result.warnings.count == 4)
    }
}
