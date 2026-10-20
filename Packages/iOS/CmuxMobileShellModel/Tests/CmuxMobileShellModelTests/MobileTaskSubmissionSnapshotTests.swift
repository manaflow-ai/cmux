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

    @Test func customWorkspaceNameChangesEffectiveRequest() {
        let template = MobileTaskTemplate(name: "Codex", icon: "agent:codex", command: "codex")
        let generated = snapshot(template: template, workspaceName: "")
        let custom = snapshot(template: template, workspaceName: "Release checklist")

        #expect(generated.workspaceTitle == generated.composition.title)
        #expect(custom.workspaceTitle == "Release checklist")
        #expect(!generated.isRequestEquivalent(to: custom))
        expectIdentityRotated(from: generated, to: custom)
    }

    @Test func workspaceGroupChangesEffectiveRequest() {
        let template = MobileTaskTemplate(name: "Codex", icon: "agent:codex", command: "codex")
        let ungrouped = snapshot(template: template)
        let grouped = snapshot(template: template, workspaceGroupID: "group-a")

        #expect(!ungrouped.isRequestEquivalent(to: grouped))
        expectIdentityRotated(from: ungrouped, to: grouped)
        #expect(grouped.draft.workspaceGroupID == "group-a")
    }

    @Test func workspaceNameUsesTrimmedWireValue() {
        let template = MobileTaskTemplate(name: "Codex", icon: "agent:codex", command: "codex")
        let padded = snapshot(template: template, workspaceName: "  Release checklist  ")
        let trimmed = snapshot(template: template, workspaceName: "Release checklist")

        #expect(padded.workspaceTitle == "Release checklist")
        #expect(padded.isRequestEquivalent(to: trimmed))
        expectIdentityPreserved(from: padded, to: trimmed)
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

    @Test func selectedModelFlowsThroughCompositionRebindingAndDraft() {
        let operationID = UUID()
        let snapshot = MobileTaskSubmissionSnapshot(
            template: MobileTaskTemplate(
                name: "Claude",
                icon: "agent:claude",
                command: "claude -- \"$CMUX_TASK_PROMPT\""
            ),
            prompt: "Ship it",
            modelID: "claude-opus-4-8",
            macDeviceID: "mac-a",
            directory: "~/cmux",
            didEditDirectory: false,
            operationID: operationID
        )
        let rebound = snapshot.withOperationID(UUID())

        #expect(
            snapshot.composition.initialCommand
                == "claude --model 'claude-opus-4-8' -- \"$CMUX_TASK_PROMPT\""
        )
        #expect(rebound.modelID == "claude-opus-4-8")
        #expect(rebound.composition == snapshot.composition)
        #expect(rebound.operationID != operationID)
        #expect(snapshot.draft.modelID == "claude-opus-4-8")
    }

    @Test func selectedModelChangesRequestEquivalence() {
        let template = MobileTaskTemplate(
            name: "Claude",
            icon: "agent:claude",
            command: "claude -- \"$CMUX_TASK_PROMPT\""
        )
        let defaultModel = snapshot(template: template)
        let selectedModel = snapshot(template: template, modelID: "claude-opus-4-8")

        #expect(!defaultModel.isRequestEquivalent(to: selectedModel))
    }

    @Test func attachmentChangesRotateRequestIdentity() {
        let template = MobileTaskTemplate(name: "Codex", icon: "agent:codex", command: "codex")
        let uploadID = UUID()
        let withoutAttachment = snapshot(template: template)
        let withAttachment = snapshot(
            template: template,
            attachments: [
                MobileTaskSubmissionAttachment(uploadID: uploadID, byteCount: 42),
            ]
        )
        let changedBytes = snapshot(
            template: template,
            attachments: [
                MobileTaskSubmissionAttachment(uploadID: uploadID, byteCount: 43),
            ]
        )

        #expect(!withoutAttachment.isRequestEquivalent(to: withAttachment))
        #expect(!withAttachment.isRequestEquivalent(to: changedBytes))
        expectIdentityRotated(from: withoutAttachment, to: withAttachment)
    }

    @Test func identicalAttachmentListsPreserveRequestIdentity() {
        let template = MobileTaskTemplate(name: "Codex", icon: "agent:codex", command: "codex")
        let attachments = [
            MobileTaskSubmissionAttachment(uploadID: UUID(), byteCount: 42),
            MobileTaskSubmissionAttachment(uploadID: UUID(), byteCount: 99),
        ]
        let before = snapshot(template: template, attachments: attachments)
        let after = snapshot(template: template, attachments: attachments)

        #expect(before.isRequestEquivalent(to: after))
        expectIdentityPreserved(from: before, to: after)
    }

    @Test(arguments: [
        (0, 3, [0..<0]),
        (6, 3, [0..<3, 3..<6]),
        (7, 3, [0..<3, 3..<6, 6..<7]),
    ])
    func attachmentChunkPlanBoundaries(
        totalBytes: Int,
        chunkBytes: Int,
        expected: [Range<Int>]
    ) {
        let plan = MobileTaskAttachmentChunkPlan(
            totalByteCount: totalBytes,
            chunkByteCount: chunkBytes
        )

        #expect(plan.ranges == expected)
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

    @Test func differentInstanceTagsChangeRequestIdentity() {
        let template = MobileTaskTemplate(
            id: UUID(),
            name: "Codex",
            icon: "agent:codex",
            command: "codex"
        )
        let nightly = snapshot(template: template, macInstanceTag: "nightly")
        let stable = snapshot(template: template, macInstanceTag: "stable")
        let legacy = snapshot(template: template, macInstanceTag: nil)

        #expect(!nightly.isRequestEquivalent(to: stable))
        #expect(!nightly.isRequestEquivalent(to: legacy))
        #expect(nightly.isRequestEquivalent(to: snapshot(template: template, macInstanceTag: "nightly")))
    }

    @Test func instanceTagSurvivesOperationRebindAndDraftRoundTrip() throws {
        let template = MobileTaskTemplate(
            id: UUID(),
            name: "Codex",
            icon: "agent:codex",
            command: "codex"
        )
        let captured = snapshot(
            template: template,
            macInstanceTag: "nightly",
            workspaceGroupID: "mac-a\u{1F}nightly\u{1F}group-a"
        )

        let rebound = captured.withOperationID(UUID())
        #expect(rebound.macInstanceTag == "nightly")

        let draft = captured.draft
        #expect(draft.macInstanceTag == "nightly")

        let decoded = try JSONDecoder().decode(
            MobileTaskComposerDraft.self,
            from: JSONEncoder().encode(draft)
        )
        #expect(decoded.macInstanceTag == "nightly")
        #expect(decoded.workspaceGroupID == "mac-a\u{1F}nightly\u{1F}group-a")
    }

    @Test func legacyDraftPayloadDecodesWithoutInstanceTag() throws {
        let legacyJSON = """
        {"prompt":"ship it","macDeviceID":"mac-a","directory":"~","didEditDirectory":false}
        """
        let decoded = try JSONDecoder().decode(
            MobileTaskComposerDraft.self,
            from: Data(legacyJSON.utf8)
        )
        #expect(decoded.macInstanceTag == nil)
        #expect(decoded.macDeviceID == "mac-a")
        #expect(decoded.workspaceGroupID == nil)
    }

    private func snapshot(
        template: MobileTaskTemplate,
        prompt: String = "ship it",
        macDeviceID: String = "mac-a",
        macInstanceTag: String? = nil,
        directory: String = "~/cmux",
        workspaceName: String = "",
        modelID: String? = nil,
        workspaceGroupID: MobileWorkspaceGroupPreview.ID? = nil,
        attachments: [MobileTaskSubmissionAttachment] = []
    ) -> MobileTaskSubmissionSnapshot {
        MobileTaskSubmissionSnapshot(
            template: template,
            prompt: prompt,
            modelID: modelID,
            macDeviceID: macDeviceID,
            macInstanceTag: macInstanceTag,
            directory: directory,
            workspaceName: workspaceName,
            workspaceGroupID: workspaceGroupID,
            didEditDirectory: false,
            attachments: attachments,
            operationID: UUID()
        )
    }
}
