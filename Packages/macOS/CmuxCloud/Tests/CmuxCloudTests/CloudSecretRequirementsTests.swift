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

    @Test
    func declaredFromFetchedFilesMatchesTheDirectoryReader() throws {
        let files = [
            ".cmux/cloud.json": #"{"env": [{"name": "DATABASE_URL", "description": "Postgres for tests"}], "setup": ["bun install"]}"#,
            ".devcontainer.json": #"{"secrets": {"HF_TOKEN": {}}}"#,
            "README.md": "not a manifest",
        ]
        let root = try makeRepository(files)
        defer { try? FileManager.default.removeItem(at: root) }
        let fromFiles = CloudSecretRequirements.declared(files: files)
        #expect(fromFiles == CloudSecretRequirements.declared(inDirectory: root))
        #expect(fromFiles.map(\.name) == ["DATABASE_URL", "HF_TOKEN"])
        #expect(CloudSecretRequirements.declared(files: [:]).isEmpty)
        #expect(CloudSecretRequirements.declaringPaths == [".cmux/cloud.json", ".devcontainer/devcontainer.json", ".devcontainer.json"])
    }

    @Test
    func oversizedManifestDeclaresNothing() throws {
        let padding = String(repeating: " ", count: CloudSecretRequirements.maxFileBytes)
        let root = try makeRepository([".cmux/cloud.json": #"{"env": ["A"]}"# + padding])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(CloudSecretRequirements.declared(inDirectory: root).isEmpty)
    }

    @Test
    func missingCountsOnlyTheScopesThatReachTheTarget() {
        let date = Date(timeIntervalSince1970: 0)
        func record(_ name: String, _ scope: CloudSecretScope) -> CloudSecretRecord {
            CloudSecretRecord(name: name, scope: scope, fingerprint: "00000000", createdAt: date, updatedAt: date, source: .manual)
        }
        let requirements = ["ANTHROPIC_API_KEY", "DATABASE_URL", "STRIPE_KEY", "ONLY_THERE", "OTHER_MACHINE"].map {
            CloudSecretRequirement(name: $0, description: nil, source: ".cmux/cloud.json")
        }
        let records = [
            record("ANTHROPIC_API_KEY", .all),
            record("DATABASE_URL", .project("github.com/acme/api")),
            record("STRIPE_KEY", .project("github.com/acme/web")),
            record("ONLY_THERE", .machine("vm-1")),
            record("OTHER_MACHINE", .machine("vm-2")),
        ]
        let forMachine = CloudSecretRequirements.missing(requirements, records: records, projectKeys: ["github.com/acme/api"], machineID: "vm-1")
        #expect(forMachine.map(\.name) == ["STRIPE_KEY", "OTHER_MACHINE"])
        let forProject = CloudSecretRequirements.missing(requirements, records: records, projectKeys: ["github.com/acme/api"], machineID: nil)
        #expect(forProject.map(\.name) == ["STRIPE_KEY", "ONLY_THERE", "OTHER_MACHINE"])
        #expect(CloudSecretRequirements.missing(requirements, records: [], projectKeys: [], machineID: nil) == requirements)
    }

    @Test
    func reservedLegacyRecordsDoNotSatisfyARequirement() {
        let date = Date(timeIntervalSince1970: 0)
        let requirement = CloudSecretRequirement(name: "CMUX_SOCKET", description: nil, source: ".cmux/cloud.json")
        let record = CloudSecretRecord(
            name: "CMUX_SOCKET",
            scope: .all,
            fingerprint: "00000000",
            createdAt: date,
            updatedAt: date,
            source: .manual
        )
        #expect(CloudSecretRequirements.missing([requirement], records: [record], projectKeys: [], machineID: nil) == [requirement])
    }

    @Test
    func reservedDeclarationsAreIgnored() {
        #expect(CloudSecretRequirements.declared(files: [
            ".cmux/cloud.json": #"{"env": ["PATH", "CMUX_SOCKET", "DATABASE_URL"]}"#
        ]).map(\.name) == ["DATABASE_URL"])
    }

    /// The vault refuses these names, so a requirement for one could never be met.
    @Test
    func declarationsTheVaultCannotStoreAreIgnored() {
        #expect(CloudSecretRequirements.declared(files: [
            ".cmux/cloud.json": #"{"env": ["my-key", "1TOKEN", "API_KEY"]}"#,
            ".devcontainer/devcontainer.json": #"{"secrets": {"API.KEY": {}, "GH_TOKEN": {}}}"#,
        ]).map(\.name) == ["API_KEY", "GH_TOKEN"])
    }

    @Test
    func checkoutResolvesOriginFromConfigAndWorktrees() throws {
        let root = try makeRepository([
            "repo/.git/config": """
            [core]
            \tbare = false
            [remote "upstream"]
            \turl = https://github.com/someone/else.git
            [remote "origin"]
            \turl = git@github.com:Acme/API.git
            \tfetch = +refs/heads/*:refs/remotes/origin/*
            """,
            "repo/src/deep/file.txt": "x",
            "repo/.git/worktrees/feature/commondir": "../..\n",
            "wt/.git": "gitdir: ../repo/.git/worktrees/feature\n",
            "plain/.git/config": "[core]\n\tbare = false\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = try #require(CloudSecretProjectCheckout.locate(from: root.appendingPathComponent("repo/src/deep")))
        #expect(nested.projectKey == "github.com/acme/api")
        #expect(nested.root.lastPathComponent == "repo")
        let worktree = try #require(CloudSecretProjectCheckout.locate(from: root.appendingPathComponent("wt")))
        #expect(worktree.projectKey == "github.com/acme/api")
        #expect(CloudSecretProjectCheckout.locate(from: root.appendingPathComponent("plain"))?.projectKey == "local/plain")
        #expect(CloudSecretProjectCheckout.originURL(config: "[remote \"origin\"]\n  url = \"https://gitlab.com/g/p.git\"\n") == "https://gitlab.com/g/p.git")
    }
}
