import AppKit
@testable import CmuxNextLayout
import Testing

/// moveWorkspaceToNewWindow in STRESS stalled the main thread 4.77 s (every-action sweep, macOS 27,
/// cmuxs-Mac-mini-4): the new window's workspace content builds its layout before the root has a window or a
/// size, and `applyPresentation` laid every pane's subtree out synchronously at the empty viewport's frames,
/// so Auto Layout broke unsatisfiable constraints in every pane's strip and content (NSISEngine
/// handleUnsatisfiableRow). Content is laid out at a real size only: by the window's layout pass once the root
/// is placed, and synchronously during motion (where it must keep up with the frame).
@MainActor
@Suite struct PaneLayoutBeforeWindowTests {
    /// Content that counts its layout passes at a size it cannot hold.
    final class Content: NSView {
        var emptyLayouts = 0
        override func layout() {
            super.layout()
            if bounds.width < 1 || bounds.height < 1 { emptyLayouts += 1 }
        }
    }

    final class Panes: LayoutPaneContentProvider {
        var made: [Content] = []
        func makeContentView(for pane: PaneID) -> NSView {
            let view = Content()
            view.needsLayout = true
            made.append(view)
            return view
        }
    }

    @Test func aRootWithoutAWindowLaysNoPaneOutAtAnEmptySize() {
        let model = LayoutModel(screens: PaneMotionBench.grid(4, 3), activeScreenID: "s", focusedPane: PaneID("p0-0"))
        let provider = Panes()
        let root = LayoutRootView(model: model, contentProvider: provider)
        root.syncWithModel()
        // A structural change before the root is placed (the daemon's echo while the window builds).
        model.apply(screens: PaneMotionBench.grid(4, 3, extraColumn: true))
        root.syncWithModel()
        #expect(!provider.made.isEmpty)
        let empty = provider.made.reduce(0) { $0 + $1.emptyLayouts }
        #expect(empty == 0, "\(empty) pane content layouts at an empty size before the root had a window")
    }
}
