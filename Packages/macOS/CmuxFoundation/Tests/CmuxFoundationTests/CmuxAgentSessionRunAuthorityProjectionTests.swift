import Testing
@testable import CmuxFoundation

@Suite("Agent session run authority projection")
struct CmuxAgentSessionRunAuthorityProjectionTests {
    @Test("spawned runs cannot retain restore authority")
    func spawnedRunCannotRetainRestoreAuthority() throws {
        let spawned = run(relationship: .spawned)

        let projection = CmuxAgentSessionRunAuthorityProjection().projection(
            recordRestoreAuthority: true,
            runs: [spawned],
            activeRunId: spawned.runId
        )

        #expect(!projection.restoreAuthority)
        #expect(try #require(projection.run).restoreAuthority == false)
    }

    @Test("all child evidence prevents restore authority")
    func childEvidencePreventsRestoreAuthority() throws {
        let childEvidence: [CmuxAgentSessionRunAuthorityProjection.AuthorityEvidence] = [
            .managedChild,
            .explicitSpawnedChild,
            .verifiedAncestorChild,
            .provisionalAmbiguousChild,
            .legacyChild,
        ]

        for evidence in childEvidence {
            let child = run(authorityEvidence: evidence)
            let projection = CmuxAgentSessionRunAuthorityProjection().projection(
                recordRestoreAuthority: true,
                runs: [child],
                activeRunId: child.runId
            )
            #expect(!projection.restoreAuthority, Comment(rawValue: evidence.rawValue))
            #expect(
                try #require(projection.run).restoreAuthority == false,
                Comment(rawValue: evidence.rawValue)
            )
        }
    }

    @Test("equal-time spawned evidence demotes either duplicate order")
    func spawnedDuplicateDemotesEitherOrder() throws {
        let root = run()
        let spawned = run(relationship: .spawned, authorityEvidence: .managedChild)

        for runs in [[root, spawned], [spawned, root]] {
            let projection = CmuxAgentSessionRunAuthorityProjection().projection(
                recordRestoreAuthority: true,
                runs: runs,
                activeRunId: root.runId
            )
            #expect(!projection.restoreAuthority)
            #expect(try #require(projection.run).restoreAuthority == false)
        }
    }

    @Test("verified fork roots retain explicit restore authority")
    func verifiedForkRootRetainsAuthority() {
        let root = run(relationship: .forked, authorityEvidence: .verifiedForkRoot)

        let projection = CmuxAgentSessionRunAuthorityProjection().projection(
            recordRestoreAuthority: false,
            runs: [root],
            activeRunId: root.runId
        )

        #expect(projection.restoreAuthority)
    }

    private func run(
        relationship: CmuxAgentSessionRunAuthorityProjection.Relationship? = nil,
        authorityEvidence: CmuxAgentSessionRunAuthorityProjection.AuthorityEvidence? = nil
    ) -> CmuxAgentSessionRunAuthorityProjection.Run {
        .init(
            runId: "run",
            relationship: relationship,
            restoreAuthority: true,
            authorityEvidence: authorityEvidence,
            startedAt: 100,
            updatedAt: 200
        )
    }
}
