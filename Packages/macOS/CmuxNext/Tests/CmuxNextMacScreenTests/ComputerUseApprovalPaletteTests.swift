// SPDX-License-Identifier: GPL-3.0-or-later
@testable import CmuxNextActions
@testable import CmuxNextMacScreen
import Testing

/// Forget and Change a Computer Use Approval as palette rows (Leo, 2026-11-08: "Every conceivable
/// possible aspect of the app"): the app id is picked from the saved approvals and the answer from
/// Always Allow / Never, with the wire values the CLI and the handler already use.
@MainActor
struct ComputerUseApprovalPaletteTests {
    @Test func bothRowsAreInThePaletteAndPickFromTheSavedApprovals() throws {
        for id in ["computerUse.approval.forget", "computerUse.approval.set"] as [ActionID] {
            let descriptor = try #require(ActionCatalog.all.first { $0.id == id })
            #expect(descriptor.isPaletteVisible, "\(id) is a palette row")
            #expect(descriptor.arguments.first?.suggestions?.source == CmuxRemoteService.approvalSuggestionSource)
        }
    }

    @Test func theAnswerIsAlwaysOrNever() throws {
        let registry = ActionRegistry(catalog: ActionCatalog.all)
        #expect(CmuxRemoteService.decisionTitles(registry).keys.sorted() == ["always", "never"])
        let argument = try #require(registry.descriptor(for: "computerUse.approval.set")?.arguments.first { $0.name == "decision" })
        #expect(argument.parse("always") == .string("always"))
        #expect(argument.parse("sometimes") == nil)
    }

    @Test func eachSavedApprovalIsARowByAppIDWithItsAnswer() {
        let rows = CmuxRemoteService.approvalChoices(
            [(appID: "com.apple.calculator", decision: "always"), (appID: "com.apple.mail", decision: "never")],
            decisions: ["always": "Always Allow", "never": "Never"])
        #expect(rows == [ActionEnumCase(value: "com.apple.calculator", title: "com.apple.calculator", subtitle: "Always Allow"),
                         ActionEnumCase(value: "com.apple.mail", title: "com.apple.mail", subtitle: "Never")])
    }
}
