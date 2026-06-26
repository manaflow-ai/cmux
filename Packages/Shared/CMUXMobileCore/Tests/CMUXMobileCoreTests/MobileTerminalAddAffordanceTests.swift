import Testing
@testable import CMUXMobileCore

/// Issue #6271: the prominent "+" button next to the iOS terminal picker must add
/// a terminal to the *current* workspace (the macOS default), not spin up a whole
/// new workspace. These pin that contract in the pure core so the toolbar wiring
/// can't silently regress.
@Suite struct MobileTerminalAddAffordanceTests {
    /// The regression guard: tapping the prominent "+" adds a terminal to the
    /// current workspace, never a new workspace.
    @Test func primaryAddButtonAddsTerminalToCurrentWorkspace() {
        #expect(MobileTerminalPrimaryAddButton.affordance == .newTerminalInCurrentWorkspace)
        #expect(MobileTerminalPrimaryAddButton.affordance != .newWorkspace)
    }

    /// The plain "plus" must drive the primary button; the layered
    /// "plus.square.on.square" (the icon testers misread as "add terminal") stays
    /// on New Workspace.
    @Test func glyphsDistinguishAddTerminalFromNewWorkspace() {
        #expect(MobileTerminalAddAffordance.newTerminalInCurrentWorkspace.systemImageName == "plus")
        #expect(MobileTerminalAddAffordance.newWorkspace.systemImageName == "plus.square.on.square")
        #expect(
            MobileTerminalPrimaryAddButton.affordance.systemImageName
                != MobileTerminalAddAffordance.newWorkspace.systemImageName
        )
    }
}
