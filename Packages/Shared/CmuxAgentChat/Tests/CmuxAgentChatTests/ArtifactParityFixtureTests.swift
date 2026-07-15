import Foundation
import Testing

@testable import CmuxAgentChat

@Suite("Session artifact parity fixtures")
struct ArtifactParityFixtureTests {
    @Test("T1 bare absolute path in assistant prose")
    func t1() throws { try expectClaude("/private/tmp/parity/T1-bare.png") }

    @Test("T2 backtick-quoted path")
    func t2() throws { try expectClaude("/Users/test/project/T2-backtick.html") }

    @Test("T3 parenthesized path")
    func t3() throws { try expectClaude("/Users/test/project/T3-parent.md") }

    @Test("T4 trailing punctuation")
    func t4() throws { try expectClaude("/private/tmp/parity/T4-trailing.png") }

    @Test("T5 render-wrapped intact source path")
    func t5() throws { try expectClaude("/private/tmp/parity/T5-intact-path.png") }

    @Test("T6 file URL")
    func t6() throws { try expectClaude("/private/tmp/parity/T6-file-url.html") }

    @Test("T7 tilde expansion uses session user home")
    func t7() throws { try expectClaude("/Users/test/parity/T7-tilde.png") }

    @Test("T9 markdown link")
    func t9() throws { try expectClaude("/private/tmp/parity/T9-markdown.html") }

    @Test("T10 user prose beyond attachment tokens")
    func t10() throws { try expectClaude("/private/tmp/parity/T10-user.png") }

    @Test("T12 thought text")
    func t12() throws { try expectClaude("/private/tmp/parity/T12-thought.md") }

    @Test("B1 absolute command argument")
    func b1() throws { try expectClaude("/private/tmp/parity/B1-arg.json") }

    @Test("B2 artifact destination remains referenced")
    func b2() throws { try expectClaude("/private/tmp/parity/B2-shot.png") }

    @Test("B3 both move endpoints remain referenced")
    func b3() throws {
        try expectClaude("/private/tmp/parity/B3-old.png")
        try expectClaude("/private/tmp/parity/B3-new.png")
    }

    @Test("B4 redirection and heredoc tokens remain referenced")
    func b4() throws {
        try expectClaude("/private/tmp/parity/B4-redir.txt")
        try expectClaude("/private/tmp/parity/B4-heredoc.txt")
    }

    @Test("O1 relative Write confirmation is represented by structured Created input")
    func o1() throws {
        try expectClaude("/Users/test/project/K2-created.txt", provenance: .created)
    }

    @Test("O2 shell stdout path")
    func o2() throws { try expectClaude("/private/tmp/parity/O2-output.png") }

    @Test("O3 every newline-listed absolute path")
    func o3() throws {
        for index in 1...50 {
            let suffix = String(format: "%02d", index)
            try expectClaude("/private/tmp/parity/O3-list-\(suffix).txt")
        }
    }

    @Test("O4 grep line and column suffix")
    func o4() throws { try expectClaude("/private/tmp/parity/O4-grep.swift") }

    @Test("O5 Claude tool-result text-block array")
    func o5() throws {
        try expectClaude("/private/tmp/parity/O5-array-one.txt")
        try expectClaude("/private/tmp/parity/O5-array-two.txt")
    }

    @Test("O6 raw pre-budget output")
    func o6() throws { try expectClaude("/private/tmp/parity/O6-beyond-budget.png") }

    @Test("O7 error output path")
    func o7() throws { try expectClaude("/private/tmp/parity/O7-error.png") }

    @Test("K1 standard path keys recurse through arrays")
    func k1() throws { try expectClaude("/private/tmp/parity/K1-nested.txt") }

    @Test("K2 structured mutation channels are Created")
    func k2() throws {
        try expectClaude("/Users/test/project/K2-created.txt", provenance: .created)
    }

    @Test("K3 MCP tool standard path key")
    func k3() throws { try expectClaude("/private/tmp/parity/K3-mcp.txt") }

    @Test("K4 structured path containing spaces")
    func k4() throws { try expectClaude("/private/tmp/parity/K4-my file.png") }

    @Test("K5 unknown absolute structured key")
    func k5() throws { try expectClaude("/private/tmp/parity/K5-unknown.txt") }

    @Test("K6 relative structured path resolves and collapses dot-dot")
    func k6() throws { try expectClaude("/Users/test/parity/K6-collapse.txt") }

    @Test("A1 patch Add Update Delete paths are Created")
    func a1() throws {
        for operation in ["add", "update", "delete"] {
            try expectCodex("/private/tmp/parity/A1-\(operation).txt", provenance: .created)
        }
    }

    @Test("A2 both rename paths remain and the destination is Created")
    func a2() throws {
        try expectCodex("/private/tmp/parity/A2-old.txt", provenance: .created)
        try expectCodex("/private/tmp/parity/A2-new.txt", provenance: .created)
    }

    @Test("A3 old custom apply-patch markers are Created")
    func a3() throws {
        try expectCodex("/private/tmp/parity/A3-add.txt", provenance: .created)
        try expectCodex("/private/tmp/parity/A3-update.txt", provenance: .created)
    }

    @Test("A4 deleted-later file remains lexical")
    func a4() throws {
        try expectCodex("/private/tmp/parity/A4-deleted.txt", provenance: .created)
    }

    @Test("N1 tmp aliases merge")
    func n1() throws {
        try expectSingleClaudeFamily("N1-alias.png", canonical: "/private/tmp/parity/N1-alias.png")
    }

    @Test("N2 var and etc aliases merge")
    func n2() throws {
        try expectSingleClaudeFamily("N2-var.png", canonical: "/private/var/parity/N2-var.png")
        try expectSingleClaudeFamily("N2-etc.conf", canonical: "/private/etc/parity/N2-etc.conf")
    }

    @Test("N3 doubled separators and trailing slash normalize")
    func n3() throws {
        try expectSingleClaudeFamily(
            "N3-normalized",
            canonical: "/private/tmp/parity/N3-normalized"
        )
    }

    @Test("N4 relative and absolute spellings merge with latest sequence")
    func n4() throws {
        let fixture = try ArtifactParityFixture.load(.claude)
        let matches = fixture.artifacts.filter { $0.path.hasSuffix("/N4-file.txt") }
        #expect(matches.count == 1)
        #expect(matches.first?.path == "/Users/test/project/N4-file.txt")
    }

    @Test("N5 percent-encoded file URL decodes")
    func n5() throws {
        try expectSingleClaudeFamily(
            "N5-percent space.png",
            canonical: "/private/tmp/parity/N5-percent space.png"
        )
    }

    @Test("sidechain Write is Created while sidechain rows stay hidden")
    func sidechain() throws {
        let fixture = try ArtifactParityFixture.load(.claude)
        try expect(
            fixture,
            path: "/private/tmp/parity/SIDE-created.txt",
            provenance: .created
        )
        try expect(fixture, path: "/private/tmp/parity/SIDE-content.txt", provenance: .referenced)
        try expect(fixture, path: "/private/tmp/parity/SIDE-output.txt", provenance: .referenced)
        #expect(fixture.parseResult.messages.allSatisfy { !$0.id.hasPrefix("side-") })
    }

    @Test("attachment tokens are Attached and not upgraded by text scanning")
    func attachmentProvenance() throws {
        try expectClaude(
            "/private/tmp/parity/T-attached/clipboard-2026-07-13-120000-abcdef12.png",
            provenance: .attached
        )
    }

    @Test("Created provenance survives later prose while sequence advances")
    func provenanceAndSequence() throws {
        let fixture = try ArtifactParityFixture.load(.claude)
        let artifact = try #require(fixture.artifact(path: "/private/tmp/parity/RANK-created.txt"))
        #expect(artifact.provenance == .created)
        #expect(artifact.lastReferencedSeq == 2)
    }

    @Test("Codex bash-lc unwrap and event-only command/output/prose channels")
    func codexSpecificChannels() throws {
        for path in [
            "/private/tmp/parity/CODEX-shell-array.txt",
            "/private/tmp/parity/CODEX-event-agent.png",
            "/private/tmp/parity/CODEX-event-command.txt",
            "/private/tmp/parity/CODEX-event-output.txt",
            "/private/tmp/parity/CODEX-O5-inline.txt",
            "/private/tmp/parity/CODEX-O6-beyond-budget.png",
        ] {
            try expectCodex(path)
        }
    }

    @Test("negative fixture sections add no excluded or non-absolute artifacts")
    func negatives() throws {
        let fixtures = try [
            ArtifactParityFixture.load(.claude),
            ArtifactParityFixture.load(.codex),
        ]
        for fixture in fixtures {
            #expect(fixture.artifacts.allSatisfy { $0.path.hasPrefix("/") })
            #expect(fixture.artifacts.allSatisfy {
                !$0.path.hasPrefix("/dev/")
                    && !$0.path.hasPrefix("/proc/")
                    && !$0.path.hasPrefix("/sys/")
                    && !$0.path.contains("://")
            })
            for fragment in [
                "1.2.3", "07/12/2026", "a/x.swift", "@scope/pkg", "node_modules",
                "sha256", "550e8400",
            ] {
                #expect(fixture.artifacts.allSatisfy { !$0.path.contains(fragment) })
            }
        }
    }

    @Test("fixture-level D minus E minus S parity is empty for both agents")
    func fixtureParity() throws {
        let audit = ArtifactDiscoveryAudit()
        for fixture in try [
            ArtifactParityFixture.load(.claude),
            ArtifactParityFixture.load(.codex),
        ] {
            let snapshot = audit.snapshot(
                lines: fixture.lines,
                agent: fixture.agent.rawValue,
                workingDirectory: fixture.workingDirectory,
                parseResult: fixture.parseResult
            )
            #expect(snapshot.violations.isEmpty, "Parity gaps: \(snapshot.violations.sorted())")
            #expect(snapshot.excludedGalleryPaths.isEmpty)
            #expect(snapshot.nonAbsoluteGalleryPaths.isEmpty)
        }
    }

    private func expectClaude(
        _ path: String,
        provenance: ChatArtifactProvenance = .referenced
    ) throws {
        try expect(ArtifactParityFixture.load(.claude), path: path, provenance: provenance)
    }

    private func expectCodex(
        _ path: String,
        provenance: ChatArtifactProvenance = .referenced
    ) throws {
        try expect(ArtifactParityFixture.load(.codex), path: path, provenance: provenance)
    }

    private func expect(
        _ fixture: ArtifactParityFixture,
        path: String,
        provenance: ChatArtifactProvenance
    ) throws {
        let artifact = try #require(fixture.artifact(path: path), "Missing \(path)")
        #expect(artifact.provenance == provenance, "Wrong provenance for \(path)")
    }

    private func expectSingleClaudeFamily(_ suffix: String, canonical: String) throws {
        let fixture = try ArtifactParityFixture.load(.claude)
        let matches = fixture.artifacts.filter { $0.path.hasSuffix(suffix) }
        #expect(matches.count == 1, "Expected one normalized spelling for \(suffix)")
        #expect(matches.first?.path == canonical)
        #expect(matches.first?.provenance == .referenced)
    }
}
