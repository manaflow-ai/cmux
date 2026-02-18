import AppKit
import SwiftUI

/// A view modifier that pauses AppKit layout traversal for inactive views.
///
/// When `isPaused` is true, the modifier finds the ForEach iteration container
/// NSView and sets `isHidden = true` on it. This causes AppKit's
/// `_layoutSubtreeIfNeeded` to skip the entire subtree, dramatically reducing
/// main thread layout cost when many workspace views are stacked in a ZStack.
///
/// When `isPaused` becomes false, the container is unhidden and marked as
/// needing layout so it picks up any geometry changes that occurred while paused.
struct LayoutPauseModifier: ViewModifier {
    let isPaused: Bool

    func body(content: Content) -> some View {
        content
            .background(LayoutPauseHelper(isPaused: isPaused))
    }
}

extension View {
    /// Pause AppKit layout traversal for this view's subtree.
    ///
    /// Use this on views inside a ZStack that are toggled via `.opacity(0/1)`.
    /// Unlike `.opacity(0)`, pausing layout prevents AppKit from walking the
    /// entire NSView subtree on every frame, which eliminates the main-thread
    /// layout storm that causes typing lag with many open workspaces.
    func layoutPaused(_ paused: Bool) -> some View {
        modifier(LayoutPauseModifier(isPaused: paused))
    }
}

// MARK: - NSViewRepresentable Helper

/// Invisible NSView inserted as a `.background()` that toggles `isHidden`
/// on its ForEach iteration container ancestor to block/unblock layout traversal.
private struct LayoutPauseHelper: NSViewRepresentable {
    let isPaused: Bool

    func makeNSView(context: Context) -> LayoutPauseNSView {
        let view = LayoutPauseNSView()
        view.alphaValue = 0
        view.frame = .zero
        return view
    }

    func updateNSView(_ nsView: LayoutPauseNSView, context: Context) {
        nsView.updatePauseState(isPaused)
    }
}

/// The actual NSView that finds and controls its container's hidden state.
final class LayoutPauseNSView: NSView {
    private weak var container: NSView?
    private var lastPaused: Bool?

    func updatePauseState(_ isPaused: Bool) {
        guard isPaused != lastPaused else { return }
        lastPaused = isPaused

        if container == nil {
            container = findContainer()
        }

        guard let container else { return }

        if isPaused {
            container.isHidden = true
        } else {
            container.isHidden = false
            // Force a layout pass to pick up any geometry changes
            // that occurred while paused (e.g., window resize).
            container.needsLayout = true
        }
    }

    /// Find the ForEach iteration container NSView.
    ///
    /// The `.background()` modifier creates a container with exactly 2 children
    /// (content + background). We need to skip past that and find the ForEach/ZStack
    /// level, which has many children (one per workspace).
    ///
    /// Strategy: walk up until we find a view whose parent has more than 2 children.
    /// This distinguishes the ZStack (N workspace children) from the .background()
    /// container (always exactly 2 children).
    ///
    /// Fallback: if no parent with >2 children exists (e.g., only 1-2 workspaces),
    /// skip the first multi-child parent (the .background() container) and use the
    /// second one.
    private func findContainer() -> NSView? {
        // Primary: find a parent with many children (the ZStack/ForEach level)
        var current: NSView? = self.superview
        while let view = current {
            if let parent = view.superview,
               parent.subviews.count > 2 {
                return view
            }
            current = view.superview
        }

        // Fallback for ≤2 workspaces: skip the first multi-child parent
        // (the .background() container) and return the child of the second one.
        current = self.superview
        var skippedFirst = false
        while let view = current {
            if let parent = view.superview,
               parent.subviews.count > 1 {
                if !skippedFirst {
                    skippedFirst = true
                    current = view.superview
                    continue
                }
                return view
            }
            current = view.superview
        }

        return nil
    }
}
