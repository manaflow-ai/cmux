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
    }

    @Test func unselectedTemplateEditKeepsSelectedRequestEquivalent() {
        let selected = MobileTaskTemplate(name: "Codex", icon: "agent:codex", command: "codex")
        let before = snapshot(template: selected)
        let after = snapshot(template: selected)

        #expect(before.isRequestEquivalent(to: after))
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
    }

    @Test func selectedTemplateDefaultDirectoryEditChangesEffectiveRequest() {
        let template = MobileTaskTemplate(name: "Codex", icon: "agent:codex", command: "codex")
        let before = snapshot(template: template, directory: "~/cmux")
        let after = snapshot(template: template, directory: "~/other")

        #expect(!before.isRequestEquivalent(to: after))
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
