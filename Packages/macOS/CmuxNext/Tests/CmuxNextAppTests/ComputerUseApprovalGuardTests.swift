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
        // Review 2 #7: cmux Remote's share and device-access confirmation raises trust too.
        let raising = [ComputerUseApprovalService.confirmModeDialogIdentifier, ComputerUseApprovalService.approvalDialogIdentifier,
                       SettingsController.userOnlyConfirmationDialogIdentifier, CmuxRemoteActions.confirmDialogIdentifier]
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
        #expect(CmuxRemoteActions.confirmSpec(title: "t", body: "b").identifier == CmuxRemoteActions.confirmDialogIdentifier)
        #expect(CmuxRemoteActions.confirmDialogIdentifier == "cmux.dialog.remote.confirm")
    }

    // MARK: Click-through guard

    /// The guard's clock is system uptime, the clock `NSEvent.timestamp` is stamped in.
    @Test func thePressGuardReadsTheEventsClock() {
        let start = ProcessInfo.processInfo.systemUptime
        #expect(ComputerUseApprovalCardPanel.uptime() >= start)
    }

    @Test func aPressInTheFirst600msAfterACardShowsOrMovesIsDropped() {
        let start: TimeInterval = 1_000
        var guardWindow = ComputerUseApprovalPressGuard()
        // Never armed: everything passes.
        #expect(guardWindow.admits(.leftMouseDown, at: start))
        guardWindow.arm(at: start)
        for press in [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown] {
            #expect(!guardWindow.admits(press, at: start), "\(press)")
            #expect(!guardWindow.admits(press, at: start + 0.599), "\(press)")
            #expect(guardWindow.admits(press, at: start + 0.6), "\(press)")
        }
        // Not presses: moves, scrolls and releases are never held back.
        #expect(guardWindow.admits(.mouseMoved, at: start))
        #expect(guardWindow.admits(.scrollWheel, at: start))
        #expect(guardWindow.admits(.leftMouseUp, at: start))
        // A move re-arms it.
        guardWindow.arm(at: start + 5)
        #expect(!guardWindow.admits(.leftMouseDown, at: start + 5.3))
        #expect(guardWindow.admits(.leftMouseDown, at: start + 5.6))
    }

    /// Review 2 #10: the guard compares when the press happened (the event's timestamp) with
    /// when the card was armed, so a main thread that stalled past the delay does not let an
    /// early click through when it finally handles it.
    @Test func aPressMadeEarlyIsDroppedEvenWhenHandledLate() {
        var now: TimeInterval = 2_000
        let panel = ComputerUseApprovalCardPanel.make(now: { now })
        defer { panel.close() }
        // The click happened 100 ms after the card showed; the main thread handles it 2 s later.
        now = 2_002
        #expect(!panel.delivers(.leftMouseDown, at: 2_000.1))
        #expect(!panel.delivers(.keyDown, at: 2_000.5))
        // One made after the delay passes, also when handled late.
        #expect(panel.delivers(.leftMouseDown, at: 2_000.6))
        // Not presses pass whenever they were made.
        #expect(panel.delivers(.mouseMoved, at: 2_000))
    }

    @Test func theCardPanelArmsAtCreationAndOnEachArm() {
        let start: TimeInterval = 3_000
        var now = start
        let panel = ComputerUseApprovalCardPanel.make(now: { now })
        defer { panel.close() }
        #expect(!panel.delivers(.leftMouseDown, at: now))
        #expect(!panel.delivers(.keyDown, at: now))
        #expect(panel.delivers(.mouseMoved, at: now))
        now = start + 0.65
        #expect(panel.delivers(.leftMouseDown, at: now))
        #expect(panel.delivers(.keyDown, at: now))
        // Moved (restack) or shown again: held back again.
        panel.armPressGuard()
        #expect(!panel.delivers(.leftMouseDown, at: now))
        now = start + 1.25
        #expect(panel.delivers(.leftMouseDown, at: now))
    }
}
