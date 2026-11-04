// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
@testable import CmuxNextApp
@testable import CmuxNextMacScreen
import CmuxNextSettings
import Foundation
import Testing

/// Review 1 #4 and #8: what raises an agent's reach answers only to the person. DEBUG
/// `debug.dialog` refuses to press, key or fill the Computer Use mode raise, an approval card and
/// the `settings set --confirm` sheet; and an approval card drops presses for 600 ms after it
/// shows or moves, by an injected clock.
@MainActor
struct ComputerUseApprovalGuardTests {
    // MARK: debug.dialog

    @Test func debugDialogRefusesToAnswerTheDialogsThatRaiseTrust() {
        let raising = [ComputerUseApprovalService.confirmModeDialogIdentifier, ComputerUseApprovalService.approvalDialogIdentifier,
                       SettingsController.userOnlyConfirmationDialogIdentifier]
        for identifier in raising {
            #expect(DebugDialog.userOnly.contains(identifier), "\(identifier)")
            #expect(DebugDialog.refuses(identifier, ["press": .string("change")]), "\(identifier)")
            #expect(DebugDialog.refuses(identifier, ["press": .string("always")]), "\(identifier)")
            #expect(DebugDialog.refuses(identifier, ["key": .string("return")]), "\(identifier)")
            #expect(DebugDialog.refuses(identifier, ["set": .object(["x": .bool(true)])]), "\(identifier)")
            // Dismissing answers no: automation may still do that.
            #expect(!DebugDialog.refuses(identifier, ["dismiss": .bool(true)]), "\(identifier)")
        }
        // Other destructive confirmations keep their shared id and stay scriptable.
        #expect(!DebugDialog.refuses("cmux.dialog.confirmation", ["press": .string("confirm")]))
        #expect(!DebugDialog.refuses(nil, ["press": .string("confirm")]))
    }

    @Test func theDialogsCarryTheirUserOnlyIds() throws {
        let request = try ComputerUseApprovalTests.request()
        #expect(ComputerUseApprovalCards.spec(for: request, icon: nil).identifier == ComputerUseApprovalService.approvalDialogIdentifier)
        let prompt = DestructiveConfirmation.Prompt(title: "t", body: "b", button: "Set")
        #expect(DestructiveConfirmation.spec(prompt, identifier: SettingsController.userOnlyConfirmationDialogIdentifier).identifier
            == SettingsController.userOnlyConfirmationDialogIdentifier)
        #expect(DestructiveConfirmation.spec(prompt).identifier == "cmux.dialog.confirmation")
    }

    // MARK: Click-through guard

    @Test func aPressInTheFirst600msAfterACardShowsOrMovesIsDropped() {
        let start = ContinuousClock.now
        var guardWindow = ComputerUseApprovalPressGuard()
        // Never armed: everything passes.
        #expect(guardWindow.admits(.leftMouseDown, at: start))
        guardWindow.arm(at: start)
        for press in [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown] {
            #expect(!guardWindow.admits(press, at: start), "\(press)")
            #expect(!guardWindow.admits(press, at: start.advanced(by: .milliseconds(599))), "\(press)")
            #expect(guardWindow.admits(press, at: start.advanced(by: .milliseconds(600))), "\(press)")
        }
        // Not presses: moves, scrolls and releases are never held back.
        #expect(guardWindow.admits(.mouseMoved, at: start))
        #expect(guardWindow.admits(.scrollWheel, at: start))
        #expect(guardWindow.admits(.leftMouseUp, at: start))
        // A move re-arms it.
        guardWindow.arm(at: start.advanced(by: .seconds(5)))
        #expect(!guardWindow.admits(.leftMouseDown, at: start.advanced(by: .milliseconds(5_300))))
        #expect(guardWindow.admits(.leftMouseDown, at: start.advanced(by: .milliseconds(5_600))))
    }

    @Test func theCardPanelArmsAtCreationAndOnEachArm() {
        let start = ContinuousClock.now
        var now = start
        let panel = ComputerUseApprovalCardPanel.make(now: { now })
        defer { panel.close() }
        #expect(!panel.delivers(.leftMouseDown))
        #expect(!panel.delivers(.keyDown))
        #expect(panel.delivers(.mouseMoved))
        now = start.advanced(by: .milliseconds(650))
        #expect(panel.delivers(.leftMouseDown))
        #expect(panel.delivers(.keyDown))
        // Moved (restack) or shown again: held back again.
        panel.armPressGuard()
        #expect(!panel.delivers(.leftMouseDown))
        now = start.advanced(by: .milliseconds(1_250))
        #expect(panel.delivers(.leftMouseDown))
    }
}
