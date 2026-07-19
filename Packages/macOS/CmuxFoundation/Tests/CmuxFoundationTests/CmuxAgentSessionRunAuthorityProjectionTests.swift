import Foundation
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

    @Test("later duplicate cannot revive durable child authority")
    func laterDuplicateCannotReviveDurableChildAuthority() throws {
        var child = run(relationship: .spawned, authorityEvidence: .managedChild)
        child.restoreAuthority = false
        child.updatedAt = 200
        var laterRoot = run(relationship: .forked, authorityEvidence: .verifiedForkRoot)
        laterRoot.updatedAt = 300

        for runs in [[child, laterRoot], [laterRoot, child]] {
            let projection = CmuxAgentSessionRunAuthorityProjection().projection(
                recordRestoreAuthority: true,
                runs: runs,
                activeRunId: child.runId
            )
            let projectedRun = try #require(projection.run)
            #expect(!projection.restoreAuthority)
            #expect(projectedRun.relationship == .spawned)
            #expect(projectedRun.authorityEvidence == .managedChild)
        }
    }

    @Test("later verified fork root recovers provisional child authority")
    func laterVerifiedForkRootRecoversProvisionalAuthority() throws {
        var provisional = run(
            relationship: .spawned,
            authorityEvidence: .provisionalAmbiguousChild
        )
        provisional.restoreAuthority = false
        provisional.updatedAt = 200
        var verifiedRoot = run(relationship: .forked, authorityEvidence: .verifiedForkRoot)
        verifiedRoot.updatedAt = 300

        let projection = CmuxAgentSessionRunAuthorityProjection().projection(
            recordRestoreAuthority: false,
            runs: [verifiedRoot, provisional],
            activeRunId: verifiedRoot.runId
        )
        let projectedRun = try #require(projection.run)
        #expect(projection.restoreAuthority)
        #expect(projectedRun.relationship == .forked)
        #expect(projectedRun.authorityEvidence == .verifiedForkRoot)
    }

    @Test("legacy records project top-level child evidence")
    func legacyRecordProjectsTopLevelChildEvidence() throws {
        for fields: [String: Any] in [
            ["restoreAuthority": true, "relationship": "spawned"],
            ["restoreAuthority": true, "authorityEvidence": "managed_child"],
            ["restoreAuthority": true, "authorityEvidence": "provisional_ambiguous_child"],
            ["restoreAuthority": true, "completedAt": 200],
        ] {
            let data = try JSONSerialization.data(withJSONObject: fields)
            #expect(
                CmuxAgentSessionRunAuthorityProjection()
                    .projection(recordJSON: data)?.restoreAuthority == false
            )
        }

        let verifiedRoot = try JSONSerialization.data(withJSONObject: [
            "restoreAuthority": true,
            "relationship": "forked",
            "authorityEvidence": "verified_fork_root",
        ])
        #expect(
            CmuxAgentSessionRunAuthorityProjection()
                .projection(recordJSON: verifiedRoot)?.restoreAuthority == true
        )
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
