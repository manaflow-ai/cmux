@testable import CmuxCloud
import Foundation
import Testing

/// Repository-declared secret names and the JSONC reader behind them.
@Suite struct CloudSecretRequirementsTests {
    func makeRepository(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-secret-requirements-\(UUID().uuidString)", isDirectory: true)
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        return root
    }

    @Test
    func readsCloudConfigAndDevcontainer() throws {
        let root = try makeRepository([
            ".cmux/cloud.json": """
            {
              // keys the agents need
              "env": [
                "ANTHROPIC_API_KEY",
                {"name": "DATABASE_URL", "description": "Postgres for tests"},
                /* duplicate below is ignored */
                "GH_TOKEN",
              ],
            }
            """,
            ".devcontainer/devcontainer.json": """
            {
              "name": "dev", // trailing comment
              "image": "mcr.microsoft.com/devcontainers/base:ubuntu",
              "secrets": {
                "OPENAI_API_KEY": { "description": "Codex", "documentationUrl": "https://example.com" },
                "GH_TOKEN": { "description": "from devcontainer" },
              },
            }
            """
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let requirements = CloudSecretRequirements.declared(inDirectory: root)
        #expect(requirements == [
            CloudSecretRequirement(name: "ANTHROPIC_API_KEY", description: nil, source: ".cmux/cloud.json"),
            CloudSecretRequirement(name: "DATABASE_URL", description: "Postgres for tests", source: ".cmux/cloud.json"),
            CloudSecretRequirement(name: "GH_TOKEN", description: nil, source: ".cmux/cloud.json"),
            CloudSecretRequirement(name: "OPENAI_API_KEY", description: "Codex", source: ".devcontainer/devcontainer.json")
        ])
    }

    @Test
    func fallsBackToRootDevcontainerFile() throws {
        let root = try makeRepository([
            ".devcontainer.json": #"{"secrets": {"HF_TOKEN": {}}}"#
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(CloudSecretRequirements.declared(inDirectory: root) == [
            CloudSecretRequirement(name: "HF_TOKEN", description: nil, source: ".devcontainer.json")
        ])
    }

    @Test
    func missingOrMalformedFilesDeclareNothing() throws {
        let empty = try makeRepository([:])
        #expect(CloudSecretRequirements.declared(inDirectory: empty).isEmpty)
        let malformed = try makeRepository([
            ".cmux/cloud.json": "{ not json",
            ".devcontainer/devcontainer.json": #"{"secrets": ["NOT_AN_OBJECT"]}"#
        ])
        defer { try? FileManager.default.removeItem(at: malformed) }
        #expect(CloudSecretRequirements.declared(inDirectory: malformed).isEmpty)
    }

    @Test
    func jsoncKeepsCommentLikeTextInsideStrings() throws {
        let text = """
        {
          "url": "https://example.com/a//b", // real comment
          "glob": "/* not a comment */",
          "quote": "say \\"hi\\" // still string",
          "list": [1, 2, /* gone */ 3,],
        }
        """
        let object = try #require(CloudSecretJSONC(text: text).object())
        #expect(object["url"] as? String == "https://example.com/a//b")
        #expect(object["glob"] as? String == "/* not a comment */")
        #expect(object["quote"] as? String == "say \"hi\" // still string")
        #expect(object["list"] as? [Int] == [1, 2, 3])
    }

    @Test
    func jsoncLeavesValidCommasAlone() throws {
        let object = try #require(CloudSecretJSONC(text: #"{"a": [1, 2], "b": {"c": 1, "d": 2}}"#).object())
        #expect(object["a"] as? [Int] == [1, 2])
        #expect((object["b"] as? [String: Int]) == ["c": 1, "d": 2])
    }
}
