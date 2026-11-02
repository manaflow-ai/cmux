import AppKit
@testable import CmuxNextLayout
import Testing

/// REOPEN-F4 (STATUS 4618): a reopened window shows its panes one new surface per frame
/// (`ContentPresentationScheduler`), and which pane got the first frame was the hash order of a
/// `Set`. The first key a person typed into the focused terminal was kept only in the cycles where
/// that terminal's pane happened to come first (5 of 15 on cmux21); in the others its surface came
/// 100-200 ms later, after the key. The pane the person types into is presented first.
@MainActor @Suite(.serialized)
struct FocusedPaneShowsFirstTests {
    /// Records the presence reports in the order the layout sends them.
    final class Panes: LayoutPaneContentProvider {
        var reported: [(PaneID, PanePresence)] = []
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
        func panePresenceDidChange(_ pane: PaneID, presence: PanePresence) { reported.append((pane, presence)) }
    }

    /// Six panes come on screen at once (a restored window goes live), the focused one last in the
    /// layout: its report goes first, then the others in layout order, never in hash order.
    @Test func panesThatComeOnScreenTogetherReportTheFocusedPaneFirstThenInLayoutOrder() {
        let ids: [PaneID] = ["p1", "p2", "p3", "p4", "p5", "p6"]
        var tree: SplitNode = .leaf(ids[5])
        for (index, id) in ids.dropLast().enumerated().reversed() {
            tree = .split(SplitID("s\(index)"), axis: .horizontal, ratio: 1 / Double(ids.count - index), a: .leaf(id), b: tree)
        }
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(tree))], activeScreenID: "s", focusedPane: "p6")
        let provider = Panes()
        let root = LayoutRootView(model: model, contentProvider: provider)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1800, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = root
        root.layoutSubtreeIfNeeded()

        let shown = provider.reported.filter { $0.1 == .visible }.map(\.0)
        #expect(Set(shown) == Set(ids), "not every pane came on screen: \(shown)")
        #expect(shown == ["p6", "p1", "p2", "p3", "p4", "p5"],
                "the focused pane p6 must be presented first, then the others in layout order; the layout reported \(shown)")
    }
}
