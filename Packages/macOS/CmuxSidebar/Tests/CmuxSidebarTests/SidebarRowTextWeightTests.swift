import AppKit
import SwiftUI
import Testing

@testable import CmuxSidebar

@Suite("SidebarRowTextWeight")
struct SidebarRowTextWeightTests {
    @Test("A resting workspace row title is lighter than semibold")
    func restingTitleIsLight() {
        let weight = SidebarRowTextWeight.workspaceTitle(isSelected: false, hasUnread: false)
        #expect(weight == .regular)
        #expect(weight.appKitWeight.rawValue < SidebarRowTextWeight.semibold.appKitWeight.rawValue)
    }

    @Test("Selected and unread workspace row titles stay semibold")
    func selectedAndUnreadTitlesAreEmphasized() {
        #expect(SidebarRowTextWeight.workspaceTitle(isSelected: true, hasUnread: false) == .semibold)
        #expect(SidebarRowTextWeight.workspaceTitle(isSelected: false, hasUnread: true) == .semibold)
        #expect(SidebarRowTextWeight.workspaceTitle(isSelected: true, hasUnread: true) == .semibold)
    }

    @Test("Group header names use one constant weight")
    func groupHeaderNameWeightIsConstant() {
        #expect(SidebarRowTextWeight.workspaceGroupHeaderName == .medium)
    }

    /// The AppKit table cells and the SwiftUI rows read these two properties
    /// separately, so a row would look different depending on which renderer
    /// drew it if the two mappings ever drifted apart.
    @Test("The AppKit and SwiftUI mappings agree for every weight")
    func appKitAndSwiftUIMappingsAgree() {
        let expected: [(SidebarRowTextWeight, NSFont.Weight, Font.Weight)] = [
            (.regular, .regular, .regular),
            (.medium, .medium, .medium),
            (.semibold, .semibold, .semibold),
        ]
        #expect(expected.count == SidebarRowTextWeight.allCases.count)
        for (weight, appKit, swiftUI) in expected {
            #expect(weight.appKitWeight == appKit)
            #expect(weight.swiftUIWeight == swiftUI)
        }
    }
}
