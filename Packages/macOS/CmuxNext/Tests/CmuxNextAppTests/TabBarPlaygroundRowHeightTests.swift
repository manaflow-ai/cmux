import AppKit
@testable import CmuxNextTabs
import Testing

/// The Tab Bar Playground (Debug menu, DEV and NIGHTLY) gives every row at least the height it asks for, on every
/// page. The Folder Corners rows (150 pt) were missing from the page's type check and drew cut down to the tab
/// strip (cmux#41989 F1).
@MainActor @Suite struct TabBarPlaygroundRowHeightTests {
    @Test func everyRowGetsTheHeightItAsksFor() {
        _ = NSApplication.shared
        for section in TabBarPlaygroundSection.allCases {
            for variant in section.variants {
                let content = variant.make(4)
                let asks = content.intrinsicContentSize.height
                #expect(asks == NSView.noIntrinsicMetric || TabBarPlaygroundView.rowHeight(for: content) >= asks,
                        "\(section) \(variant.name): \(TabBarPlaygroundView.rowHeight(for: content)) pt for a \(asks) pt row")
            }
        }
    }

    @Test func aFolderCornersRowIsItsOwnHeight() {
        _ = NSApplication.shared
        for variant in FolderCornerPlaygroundVariants().all {
            #expect(TabBarPlaygroundView.rowHeight(for: variant.make(4)) == FolderCornerPlaygroundRow.preferredHeight)
        }
    }
}
