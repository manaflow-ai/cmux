import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Lawrence 2026-10-21 (a sidebar card: the name, "Done", "Claude Code · claude-opus-5-5", a reply
/// wrapped to two lines): "vertical alignment here is still bad". Every icon on the workspace card
/// (the kind icon, the status mark, each fact's icon) centers on the middle of its text's first
/// line's capitals, also when the name or a fact wraps.
@MainActor @Suite(.serialized) struct WorkspaceHoverCardIconLineTests {
    private static func card(title: String, notes: String) -> WorkspaceHoverCardView {
        var workspace = SidebarWorkspace(id: WorkspaceID("ws-icons"), title: title, directory: "~/Projects/site", branch: "main")
        workspace.workspaceDescription = notes
        workspace.taskStatus = .done
        let card = WorkspaceHoverCardView()
        card.configure(.make(workspace, machine: nil, now: Date()))
        card.detailsToggle.performClick(nil)
        card.frame = NSRect(origin: .zero, size: card.fittingSize)
        card.layoutSubtreeIfNeeded()
        return card
    }

    /// Each horizontal row's leading mark and the text beside it: the first arranged view that is
    /// not text, and the first text after it.
    private static func iconLines(in view: NSView) -> [(icon: NSView, line: any ShownText)] {
        var found: [(NSView, any ShownText)] = []
        if let stack = view as? NSStackView, stack.orientation == .horizontal {
            let shown = stack.arrangedSubviews.filter { !$0.isHidden }
            if let icon = shown.first, !(icon is any ShownText), !(icon is NSStackView),
               let line = shown.dropFirst().compactMap({ $0 as? any ShownText }).first {
                found.append((icon, line))
            }
        }
        for child in view.subviews where !child.isHidden { found += iconLines(in: child) }
        return found
    }

    private static func capMiddle(of label: any ShownText, in view: NSView) -> CGFloat {
        let frame = view.convert(label.bounds, from: label)
        let capHalf = (label.font?.capHeight ?? 0) / 2
        let baselineFromTop = label.firstBaselineOffsetFromTop
        return view.isFlipped ? frame.minY + baselineFromTop - capHalf : frame.maxY - baselineFromTop + capHalf
    }

    @Test(arguments: [false, true])
    func everyIconSitsOnItsFirstLinesCapitals(wrapped: Bool) throws {
        let card = wrapped
            ? Self.card(title: "A workspace name long enough to wrap onto a second line of its card",
                        notes: "These notes are long enough that they wrap onto a second line of the card for sure")
            : Self.card(title: "IOS & Android simulators", notes: "Short notes")
        let pairs = Self.iconLines(in: card)
        try #require(pairs.count >= 3, "found \(pairs.count) icon rows in \(card.lines)")
        for (icon, line) in pairs {
            let offset = card.convert(icon.bounds, from: icon).midY - Self.capMiddle(of: line, in: card)
            #expect(abs(offset) <= 0.5, "\"\(line.stringValue)\": its icon's middle is \(offset) pt off its first line's capitals")
        }
    }
}
