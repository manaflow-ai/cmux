import CoreGraphics
import SwiftUI
import Testing
@testable import CmuxMobileShellUI

@Suite struct WorkspaceDetailToolbarTitleSizingTests {
    @Test func compactPortraitUsesTheSmallestBaseCap() {
        #expect(
            WorkspaceDetailToolbarTitleSizing.maximumTitleWidth(
                horizontalSizeClass: .compact,
                verticalSizeClass: .regular,
                leadingItemCount: 1,
                trailingItemCount: 1
            ) == WorkspaceDetailToolbarTitleSizing.compactPortraitMaximum
        )
    }

    @Test func compactLandscapeGetsMoreTitleRoom() {
        #expect(
            WorkspaceDetailToolbarTitleSizing.maximumTitleWidth(
                horizontalSizeClass: .compact,
                verticalSizeClass: .compact,
                leadingItemCount: 1,
                trailingItemCount: 1
            ) == WorkspaceDetailToolbarTitleSizing.compactLandscapeMaximum
        )
    }

    @Test func regularPortraitUsesThePortraitCap() {
        #expect(
            WorkspaceDetailToolbarTitleSizing.maximumTitleWidth(
                horizontalSizeClass: .regular,
                verticalSizeClass: .regular,
                leadingItemCount: 1,
                trailingItemCount: 1
            ) == WorkspaceDetailToolbarTitleSizing.regularPortraitMaximum
        )
    }

    @Test func regularLandscapeUsesTheLandscapeCap() {
        #expect(
            WorkspaceDetailToolbarTitleSizing.maximumTitleWidth(
                horizontalSizeClass: .regular,
                verticalSizeClass: .compact,
                leadingItemCount: 1,
                trailingItemCount: 1
            ) == WorkspaceDetailToolbarTitleSizing.regularLandscapeMaximum
        )
    }

    @Test func eachAdditionalTrailingItemShrinksTheCap() {
        let oneItem = WorkspaceDetailToolbarTitleSizing.maximumTitleWidth(
            horizontalSizeClass: .compact,
            verticalSizeClass: .regular,
            leadingItemCount: 1,
            trailingItemCount: 1
        )
        let twoItems = WorkspaceDetailToolbarTitleSizing.maximumTitleWidth(
            horizontalSizeClass: .compact,
            verticalSizeClass: .regular,
            leadingItemCount: 1,
            trailingItemCount: 2
        )

        #expect(oneItem - twoItems
            == WorkspaceDetailToolbarTitleSizing.additionalTrailingItemReserve)
    }

    @Test func extraLeadingControlAlsoConsumesTitleRoom() {
        let oneLeadingItem = WorkspaceDetailToolbarTitleSizing.maximumTitleWidth(
            horizontalSizeClass: .regular,
            verticalSizeClass: .regular,
            leadingItemCount: 1,
            trailingItemCount: 2
        )
        let twoLeadingItems = WorkspaceDetailToolbarTitleSizing.maximumTitleWidth(
            horizontalSizeClass: .regular,
            verticalSizeClass: .regular,
            leadingItemCount: 2,
            trailingItemCount: 2
        )

        #expect(oneLeadingItem - twoLeadingItems
            == WorkspaceDetailToolbarTitleSizing.additionalLeadingItemReserve)
    }

    @Test func titleCapHasASafeMinimumWhenManyItemsAreShown() {
        #expect(
            WorkspaceDetailToolbarTitleSizing.maximumTitleWidth(
                horizontalSizeClass: .compact,
                verticalSizeClass: .regular,
                leadingItemCount: 2,
                trailingItemCount: 8
            ) == WorkspaceDetailToolbarTitleSizing.minimumTitleWidth
        )
    }
}
