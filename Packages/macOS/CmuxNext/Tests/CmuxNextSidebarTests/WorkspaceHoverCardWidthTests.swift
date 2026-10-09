import AppKit
import Foundation
import Testing
@testable import CmuxNextSidebar

/// POLISH (Leo 2026-10-08): a popover sizes to its content. A short
/// workspace card is no wider than its name and facts need; a long name
/// wraps at the card's widest.
@MainActor @Suite struct WorkspaceHoverCardWidthTests {
    private func width(_ title: String) -> CGFloat {
        let view = WorkspaceHoverCardView()
        view.configure(WorkspaceHoverCardContent(title: title, icon: .terminal, age: "4w",
                                                 facts: [.init(icon: .folder, text: "site")]))
        view.layoutSubtreeIfNeeded()
        return view.fittingSize.width
    }

    @Test func aShortCardIsNarrowerThanTheWidest() {
        let short = width("api")
        #expect(short < WorkspaceHoverCardView.cardWidth)
        #expect(short >= WorkspaceHoverCardView.minCardWidth)
    }

    @Test func aLongNameWrapsAtTheWidest() {
        let long = width(String(repeating: "Play Starsector campaign ", count: 4))
        #expect(long == WorkspaceHoverCardView.cardWidth)
    }
}
