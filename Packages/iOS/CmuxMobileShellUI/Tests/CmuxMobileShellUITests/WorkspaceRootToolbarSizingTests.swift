import CoreGraphics
import Testing
@testable import CmuxMobileShellUI

@Suite struct WorkspaceRootToolbarSizingTests {
    @Test func phoneSplitSidebarMovesThePickerIntoTheLeadingGroup() {
        // Duo portrait: a 320 pt compact-width sidebar with the leading toggle.
        #expect(WorkspaceRootToolbarSizing.usesLeadingTitlePlacement(
            contentWidth: 320,
            isRegularWidth: false,
            hostsSidebarToggle: true
        ))
    }

    @Test func wideSidebarKeepsThePrincipalPicker() {
        #expect(!WorkspaceRootToolbarSizing.usesLeadingTitlePlacement(
            contentWidth: 420,
            isRegularWidth: false,
            hostsSidebarToggle: true
        ))
    }

    @Test func compactStackWithoutASidebarKeepsThePrincipalPicker() {
        #expect(!WorkspaceRootToolbarSizing.usesLeadingTitlePlacement(
            contentWidth: 320,
            isRegularWidth: false,
            hostsSidebarToggle: false
        ))
    }

    @Test func narrowIPadSidebarStillMovesThePicker() {
        #expect(WorkspaceRootToolbarSizing.usesLeadingTitlePlacement(
            contentWidth: 320,
            isRegularWidth: true,
            hostsSidebarToggle: false
        ))
    }

    @Test func phoneSplitSidebarDrawsThePickerAsAnIcon() {
        #expect(WorkspaceRootToolbarSizing.usesIconTitleLabel(
            contentWidth: 320,
            isRegularWidth: false,
            hostsSidebarToggle: true
        ))
    }

    @Test func iPadAndWideSidebarsKeepTheTitledPicker() {
        #expect(!WorkspaceRootToolbarSizing.usesIconTitleLabel(
            contentWidth: 320,
            isRegularWidth: true,
            hostsSidebarToggle: true
        ))
        #expect(!WorkspaceRootToolbarSizing.usesIconTitleLabel(
            contentWidth: 420,
            isRegularWidth: false,
            hostsSidebarToggle: true
        ))
        #expect(!WorkspaceRootToolbarSizing.usesIconTitleLabel(
            contentWidth: 320,
            isRegularWidth: false,
            hostsSidebarToggle: false
        ))
    }

    @Test func unmeasuredWidthKeepsThePrincipalPicker() {
        #expect(!WorkspaceRootToolbarSizing.usesLeadingTitlePlacement(
            contentWidth: 0,
            isRegularWidth: true,
            hostsSidebarToggle: true
        ))
    }
}
