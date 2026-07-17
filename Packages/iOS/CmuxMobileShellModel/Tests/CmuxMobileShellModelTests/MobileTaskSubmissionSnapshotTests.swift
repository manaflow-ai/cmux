import Foundation
import Testing
@testable import CmuxMobileShellModel

@Suite struct MobileTaskSubmissionSnapshotTests {
    @Test func selectedTemplateNameAndIconEditKeepsEquivalentRequest() {
        let templateID = UUID()
        let before = snapshot(template: MobileTaskTemplate(
            id: templateID,
            name: "Codex",
            icon: "agent:codex",
            command: "codex"
        ))
        let after = snapshot(template: MobileTaskTemplate(
            id: templateID,
            name: "Renamed Codex",
            icon: "sparkles",
            command: "codex"
        ))

        #expect(before.isRequestEquivalent(to: after))
        expectIdentityPreserved(from: before, to: after)
    }

    @Test func unselectedTemplateEditKeepsSelectedRequestEquivalent() {
        let selected = MobileTaskTemplate(name: "Codex", icon: "agent:codex", command: "codex")
        let before = snapshot(template: selected)
        let after = snapshot(template: selected)

        #expect(before.isRequestEquivalent(to: after))
        expectIdentityPreserved(from: before, to: after)
    }

    @Test func selectedTemplateCommandEditChangesRequest() {
        let templateID = UUID()
        let before = snapshot(template: MobileTaskTemplate(
            id: templateID,
            name: "Codex",
            icon: "agent:codex",
            command: "codex"
        ))
        let after = snapshot(template: MobileTaskTemplate(
            id: templateID,
            name: "Codex",
            icon: "agent:codex",
            command: "codex --dangerously-bypass-approvals-and-sandbox"
        ))

        #expect(!before.isRequestEquivalent(to: after))
        expectIdentityRotated(from: before, to: after)
    }

    @Test func commandSurroundingWhitespaceChangesRequestIdentity() {
        let before = snapshot(template: MobileTaskTemplate(
            name: "Codex",
            icon: "agent:codex",
            command: "codex"
        ))
        let after = snapshot(template: MobileTaskTemplate(
            name: "Codex",
            icon: "agent:codex",
            command: "  codex  "
        ))

        #expect(!before.isRequestEquivalent(to: after))
        expectIdentityRotated(from: before, to: after)
    }

    @Test func canonicallyEquivalentCommandBytesChangeRequestIdentity() {
        let before = snapshot(template: MobileTaskTemplate(
            name: "Codex",
            icon: "agent:codex",
            command: "codex caf\u{00E9}"
        ))
        let after = snapshot(template: MobileTaskTemplate(
            name: "Codex",
            icon: "agent:codex",
            command: "codex cafe\u{301}"
        ))

        #expect(!before.isRequestEquivalent(to: after))
        expectIdentityRotated(from: before, to: after)
    }

    @Test func canonicallyEquivalentPromptEnvironmentAndTitleBytesChangeRequestIdentity() {
        let template = MobileTaskTemplate(name: "Codex", icon: "agent:codex", command: "codex")
        let before = snapshot(template: template, prompt: "caf\u{00E9}")
        let after = snapshot(template: template, prompt: "cafe\u{301}")

        #expect(!before.isRequestEquivalent(to: after))
        expectIdentityRotated(from: before, to: after)
    }

    @Test func canonicallyEquivalentDirectoryBytesChangeRequestIdentity() {
        let template = MobileTaskTemplate(name: "Codex", icon: "agent:codex", command: "codex")
        let before = snapshot(template: template, directory: "~/caf\u{00E9}")
        let after = snapshot(template: template, directory: "~/cafe\u{301}")

        #expect(!before.isRequestEquivalent(to: after))
        expectIdentityRotated(from: before, to: after)
    }

    @Test func canonicallyEquivalentMacIdentifierBytesChangeRequestIdentity() {
        let template = MobileTaskTemplate(name: "Codex", icon: "agent:codex", command: "codex")
        let before = snapshot(template: template, macDeviceID: "mac-caf\u{00E9}")
        let after = snapshot(template: template, macDeviceID: "mac-cafe\u{301}")

        #expect(!before.isRequestEquivalent(to: after))
        expectIdentityRotated(from: before, to: after)
    }

    @Test func selectedTemplateDefaultDirectoryEditChangesEffectiveRequest() {
        let template = MobileTaskTemplate(name: "Codex", icon: "agent:codex", command: "codex")
        let before = snapshot(template: template, directory: "~/cmux")
        let after = snapshot(template: template, directory: "~/other")

        #expect(!before.isRequestEquivalent(to: after))
        expectIdentityRotated(from: before, to: after)
    }

    @Test func selectedTemplateChangeWithDifferentCompositionChangesRequest() {
        let before = snapshot(template: MobileTaskTemplate(
            name: "Codex",
            icon: "agent:codex",
            command: "codex"
        ))
        let after = snapshot(template: MobileTaskTemplate(
            name: "Claude",
            icon: "agent:claude",
            command: "claude"
        ))

        #expect(!before.isRequestEquivalent(to: after))
        expectIdentityRotated(from: before, to: after)
    }

    @Test func selectedTemplateDeletionRotatesIdentity() {
        let before = snapshot(template: MobileTaskTemplate(
            name: "Codex",
            icon: "agent:codex",
            command: "codex"
        ))

        expectIdentityRotated(from: before, to: nil)
    }

    @Test func requestEquivalenceMatchesSentWorkspaceSpec() {
        let before = MobileTaskSubmissionSnapshot(
            template: MobileTaskTemplate(name: "Codex", icon: "agent:codex", command: "codex"),
            prompt: " ship it ",
            macDeviceID: "mac-a",
            directory: " ~/cmux ",
            didEditDirectory: false,
            operationID: UUID()
        )
        let after = MobileTaskSubmissionSnapshot(
            template: MobileTaskTemplate(name: "Renamed", icon: "sparkles", command: "codex"),
            prompt: "ship it",
            macDeviceID: "mac-a",
            directory: "~/cmux",
            didEditDirectory: true,
            operationID: UUID()
        )

        #expect(before.isRequestEquivalent(to: after))
        #expect(!before.isRequestEquivalent(to: snapshot(
            template: MobileTaskTemplate(name: "Codex", icon: "agent:codex", command: "codex"),
            macDeviceID: "mac-b"
        )))
    }

    @Test func dirtyMarksDeferOneHundredKilobytePromptCompositionUntilResolution() throws {
        let template = MobileTaskTemplate(name: "Codex", icon: "agent:codex", command: "codex")
        let baseline = snapshot(template: template, prompt: "baseline")
        var identity = MobileTaskSubmissionIdentity(
            id: baseline.operationID,
            initialRequest: baseline
        )
        let largePrompt = String(repeating: "x", count: 100_000)
        var buildCount = 0

        for _ in 0..<10_000 {
            identity.markRequestDirty()
        }
        #expect(buildCount == 0)
        let resolved = try #require(identity.resolveCurrentRequest {
            buildCount += 1
            return self.snapshot(template: template, prompt: largePrompt)
        })
        #expect(buildCount == 1)
        let resolvedID = resolved.operationID

        let cleanRetry = identity.resolveCurrentRequest {
            buildCount += 1
            return self.snapshot(template: template, prompt: largePrompt)
        }
        #expect(buildCount == 1)
        #expect(cleanRetry?.operationID == resolvedID)
    }

    @Test func editThenRevertBeforeResolutionRestoresBaselineID() throws {
        let template = MobileTaskTemplate(name: "Codex", icon: "agent:codex", command: "codex")
        let baseline = snapshot(template: template, prompt: "A")
        var identity = MobileTaskSubmissionIdentity(
            id: baseline.operationID,
            initialRequest: baseline
        )

        identity.markRequestDirty()
        identity.markRequestDirty()
        let resolved = try #require(identity.resolveCurrentRequest {
            self.snapshot(template: template, prompt: "A")
        })

        #expect(resolved.operationID == baseline.operationID)
    }

    @Test func resolvedBaselineAndDivergentRequestsRestoreBothIDs() throws {
        let template = MobileTaskTemplate(name: "Codex", icon: "agent:codex", command: "codex")
        let baseline = snapshot(template: template, prompt: "A")
        var identity = MobileTaskSubmissionIdentity(
            id: baseline.operationID,
            initialRequest: baseline
        )
        identity.markRequestDirty()
        let divergent = try #require(identity.resolveCurrentRequest {
            self.snapshot(template: template, prompt: "B")
        })
        #expect(divergent.operationID != baseline.operationID)

        identity.markRequestDirty()
        let restoredBaseline = try #require(identity.resolveCurrentRequest {
            self.snapshot(template: template, prompt: "A")
        })
        identity.markRequestDirty()
        let restoredDivergent = try #require(identity.resolveCurrentRequest {
            self.snapshot(template: template, prompt: "B")
        })

        #expect(restoredBaseline.operationID == baseline.operationID)
        #expect(restoredDivergent.operationID == divergent.operationID)
    }

    @Test func missingTemplateTransitionUsesStableDivergentID() {
        let template = MobileTaskTemplate(name: "Codex", icon: "agent:codex", command: "codex")
        let baseline = snapshot(template: template)
        var identity = MobileTaskSubmissionIdentity(
            id: baseline.operationID,
            initialRequest: baseline
        )
        identity.markRequestDirty()
        #expect(identity.resolveCurrentRequest { nil } == nil)
        let missingID = identity.id
        identity.markRequestDirty()
        _ = identity.resolveCurrentRequest { baseline }
        #expect(identity.id == baseline.operationID)
        identity.markRequestDirty()
        #expect(identity.resolveCurrentRequest { nil } == nil)
        #expect(identity.id == missingID)
    }

    @Test func adoptingFailedSubmissionCreatesNewRetryBaseline() throws {
        let template = MobileTaskTemplate(name: "Codex", icon: "agent:codex", command: "codex")
        let original = snapshot(template: template, prompt: "A")
        let failed = snapshot(template: template, prompt: "B")
        var identity = MobileTaskSubmissionIdentity(
            id: original.operationID,
            initialRequest: original
        )

        identity.adoptResolvedRequest(failed)
        let retry = try #require(identity.resolveCurrentRequest {
            self.snapshot(template: template, prompt: "unused")
        })
        #expect(retry.operationID == failed.operationID)
        #expect(retry.prompt == failed.prompt)
    }

    @Test func retryKeepsFailedOperationIdentityUntilTheRequestChanges() throws {
        let template = MobileTaskTemplate(name: "Codex", icon: "agent:codex", command: "codex")
        let failed = snapshot(template: template, prompt: "A")
        var identity = MobileTaskSubmissionIdentity(
            id: failed.operationID,
            initialRequest: failed
        )

        identity.adoptResolvedRequest(failed)
        let unchangedRetry = try #require(identity.resolveCurrentRequest { nil })
        #expect(unchangedRetry.operationID == failed.operationID)

        identity.markRequestDirty()
        let editedRequest = try #require(identity.resolveCurrentRequest {
            self.snapshot(template: template, prompt: "B")
        })
        #expect(editedRequest.operationID != failed.operationID)

        let editedRetry = try #require(identity.resolveCurrentRequest { nil })
        #expect(editedRetry.operationID == editedRequest.operationID)
    }

    @Test func rebindingOperationIDPreservesExactWireRequest() {
        let original = snapshot(
            template: MobileTaskTemplate(name: "Codex", icon: "agent:codex", command: "codex caf\u{00E9}"),
            prompt: "cafe\u{301}",
            macDeviceID: "mac-caf\u{00E9}",
            directory: " ~/cafe\u{301} "
        )
        let rebound = original.withOperationID(UUID())

        #expect(rebound.operationID != original.operationID)
        #expect(rebound.composition == original.composition)
        #expect(rebound.trimmedDirectory == original.trimmedDirectory)
    }

    private func expectIdentityPreserved(
        from before: MobileTaskSubmissionSnapshot?,
        to after: MobileTaskSubmissionSnapshot?
    ) {
        var identity = MobileTaskSubmissionIdentity(initialRequest: before)
        let originalID = identity.id

        identity.markRequestDirty()
        _ = identity.resolveCurrentRequest { after }

        #expect(identity.id == originalID)
    }

    private func expectIdentityRotated(
        from before: MobileTaskSubmissionSnapshot?,
        to after: MobileTaskSubmissionSnapshot?
    ) {
        var identity = MobileTaskSubmissionIdentity(initialRequest: before)
        let originalID = identity.id

        identity.markRequestDirty()
        _ = identity.resolveCurrentRequest { after }

        #expect(identity.id != originalID)
    }

    private func snapshot(
        template: MobileTaskTemplate,
        prompt: String = "ship it",
        macDeviceID: String = "mac-a",
        directory: String = "~/cmux"
    ) -> MobileTaskSubmissionSnapshot {
        MobileTaskSubmissionSnapshot(
            template: template,
            prompt: prompt,
            macDeviceID: macDeviceID,
            directory: directory,
            didEditDirectory: false,
            operationID: UUID()
        )
    }
}
