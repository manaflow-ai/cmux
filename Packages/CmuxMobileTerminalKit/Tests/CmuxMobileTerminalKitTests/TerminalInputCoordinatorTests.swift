import Foundation
import Testing
@testable import CmuxMobileTerminalKit

@MainActor
@Suite struct TerminalInputCoordinatorTests {
    @Test func plainTextPassesThrough() {
        let coordinator = TerminalInputCoordinator()
        #expect(coordinator.resolveCommittedText("ls") == .sendText("ls"))
    }

    @Test func armedControlTranslatesSingleCharAndConsumes() {
        let coordinator = TerminalInputCoordinator()
        coordinator.tapModifier(.control, now: 0)
        #expect(coordinator.isArmed(.control))
        #expect(coordinator.resolveCommittedText("c") == .sendBytes(Data([0x03])))
        #expect(!coordinator.isArmed(.control))
    }

    @Test func stickyControlSurvivesConsumption() {
        let coordinator = TerminalInputCoordinator()
        coordinator.tapModifier(.control, now: 0)
        coordinator.tapModifier(.control, now: 0.1) // double tap -> sticky
        #expect(coordinator.isStickyOn(.control))
        #expect(coordinator.resolveCommittedText("c") == .sendBytes(Data([0x03])))
        #expect(coordinator.isArmed(.control))
    }

    @Test func armedControlWithMultiCharTextFallsBackToText() {
        let coordinator = TerminalInputCoordinator()
        coordinator.tapModifier(.control, now: 0)
        #expect(coordinator.resolveCommittedText("hello") == .sendText("hello"))
    }

    @Test func armedAlternatePrefixesEscape() {
        let coordinator = TerminalInputCoordinator()
        coordinator.tapModifier(.alternate, now: 0)
        #expect(coordinator.resolveCommittedText("b") == .sendBytes(Data([0x1B, UInt8(ascii: "b")])))
    }

    @Test func armedCommandMapsReadlineShortcuts() {
        let coordinator = TerminalInputCoordinator()
        coordinator.tapModifier(.command, now: 0)
        #expect(coordinator.resolveCommittedText("a") == .sendBytes(Data([0x01])))
        coordinator.tapModifier(.command, now: 10)
        #expect(coordinator.resolveCommittedText("x") == .sendText("x"))
    }

    @Test func armedShiftUppercases() {
        let coordinator = TerminalInputCoordinator()
        coordinator.tapModifier(.shift, now: 0)
        #expect(coordinator.resolveCommittedText("abc") == .sendText("ABC"))
        #expect(!coordinator.isArmed(.shift))
    }

    @Test func backspaceVariants() {
        let coordinator = TerminalInputCoordinator()
        #expect(coordinator.resolveBackspace() == .plainDelete)

        coordinator.tapModifier(.command, now: 0)
        #expect(coordinator.resolveBackspace() == .emission(.sendBytes(Data([0x15]))))

        coordinator.tapModifier(.control, now: 10)
        #expect(coordinator.resolveBackspace() == .plainDelete)
        #expect(!coordinator.isArmed(.control))

        coordinator.tapModifier(.alternate, now: 20)
        let resolution = coordinator.resolveBackspace()
        guard case .emission(.sendBytes(let bytes)) = resolution else {
            Issue.record("expected alt-delete bytes, got \(resolution)")
            return
        }
        #expect(!bytes.isEmpty)
    }

    @Test func zoomDisarmsEverything() {
        let coordinator = TerminalInputCoordinator()
        coordinator.tapModifier(.control, now: 0)
        coordinator.tapModifier(.shift, now: 1)
        let resolution = coordinator.resolveAccessoryAction(.zoomIn, now: 2)
        #expect(resolution == .zoom(.increase))
        #expect(!coordinator.isArmed(.control))
        #expect(!coordinator.isArmed(.shift))
    }

    @Test func accessoryTapWithControlArmedUsesRawOutput() {
        let coordinator = TerminalInputCoordinator()
        coordinator.tapModifier(.control, now: 0)
        let resolution = coordinator.resolveAccessoryAction(.ctrlC, now: 1)
        #expect(resolution == .emission(.sendBytes(Data([0x03]))))
        #expect(!coordinator.isArmed(.control))
    }

    @Test func accessoryTapWithAlternateArmedWordArrows() {
        let coordinator = TerminalInputCoordinator()
        coordinator.tapModifier(.alternate, now: 0)
        let resolution = coordinator.resolveAccessoryAction(.leftArrow, now: 1)
        let expected = TerminalKeyEncoder.encode(specialKey: .leftArrow, modifiers: [.alternate])
        #expect(resolution == .emission(.sendBytes(expected ?? Data())))
    }

    @Test func accessoryTapWithCommandArmedMapsLineStartEnd() {
        let coordinator = TerminalInputCoordinator()
        coordinator.tapModifier(.command, now: 0)
        #expect(coordinator.resolveAccessoryAction(.leftArrow, now: 1) == .emission(.sendBytes(Data([0x01]))))
        coordinator.tapModifier(.command, now: 10)
        #expect(coordinator.resolveAccessoryAction(.rightArrow, now: 11) == .emission(.sendBytes(Data([0x05]))))
    }

    @Test func modifierTapToggles() {
        let coordinator = TerminalInputCoordinator()
        #expect(coordinator.resolveAccessoryAction(.control, now: 0) == AccessoryResolutionHelper.none)
        #expect(coordinator.isArmed(.control))
        // A second tap inside the double-tap window promotes to sticky.
        _ = coordinator.resolveAccessoryAction(.control, now: 0.1)
        #expect(coordinator.isStickyOn(.control))
    }

    @Test func plainShortcutEmitsItsOutput() {
        let coordinator = TerminalInputCoordinator()
        #expect(coordinator.resolveAccessoryAction(.escape, now: 0) == .emission(.sendBytes(Data([0x1B]))))
        #expect(coordinator.resolveAccessoryAction(.pageDown, now: 1) == .emission(.sendBytes(Data([0x1B, 0x5B, 0x36, 0x7E]))))
    }
}

/// Disambiguates `.none` from `Optional.none` in `#expect` comparisons.
private enum AccessoryResolutionHelper {
    static let none = TerminalInputCoordinator.AccessoryResolution.none
}
