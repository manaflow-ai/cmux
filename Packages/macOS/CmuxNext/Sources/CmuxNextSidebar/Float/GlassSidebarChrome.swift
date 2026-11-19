public import AppKit
public import CmuxNextDesign
import CmuxNextCompat
import Observation

/// The glass sidebar experiment in one window (`experiments.glassSidebarExtension`, Settings > Experimental, off by
/// default; a taste build of 2026-11-19, Leo: "we might as well just build out a bunch that are really promising and
/// just see how they fare"). The sidebar is an inset glass card (the floating sidebar's surface,
/// ``SidebarContainerView/glassDocked``), the panes run full-bleed to the window's edges, and the active pane's content
/// extends, mirrored and blurred, under the card (``ContentBackgroundExtension``, macOS 26 and later).
///
/// ``apply()`` sets the sidebar's card and the extension in one turn and hands the window the new look (`changed`),
/// so the window's pins move in the same layout pass: the sidebar, the panes and the extension move together. The
/// window keeps the look it was handed and reads only that while it lays out. Off, the look is
/// ``GlassSidebarLook/off`` and nothing changes.
@MainActor
public final class GlassSidebarChrome {
    /// What the window draws now.
    public private(set) var look: GlassSidebarLook = .off
    private let sidebar: SidebarContainerView
    private let content: NSView
    private weak var root: NSView?
    private let reduceTransparency: @MainActor () -> Bool
    private let changed: @MainActor (GlassSidebarLook) -> Void
    private let backgroundExtension = ContentBackgroundExtension()

    /// - Parameters:
    ///   - content: The window's main pane, a direct subview of `root`.
    ///   - changed: Called with the new look after it changed (in init too): the window re-pins its main pane.
    public init(sidebar: SidebarContainerView, content: NSView, root: NSView,
                reduceTransparency: @escaping @MainActor () -> Bool, changed: @escaping @MainActor (GlassSidebarLook) -> Void) {
        (self.sidebar, self.content, self.root, self.reduceTransparency, self.changed) = (sidebar, content, root, reduceTransparency, changed)
        // The first window opens in its look (no change after it shows).
        apply()
        // The setting, the variant and the gutter the card's inset comes from; the first emission repeats `apply()`.
        // The loop ends at the first change after the window let this go.
        Task { [weak self] in
            for await _ in ObservationStream({ (DesignSettings.shared.glassSidebarExtension, GlassSidebarVariant.tunable.value,
                                                Metrics.mainPaneGutter) }) {
                guard let self else { return }
                apply()
            }
        }
    }

    /// Applies the current setting, variant and Reduce Transparency (which extends nothing). Idempotent.
    public func apply() {
        let next = GlassSidebarLook.current(reduceTransparency: reduceTransparency())
        sidebar.glassDockedInset = next.sidebarInset
        sidebar.glassDocked = next.glassSidebar
        if let root { backgroundExtension.apply(extending: next.extendsContent, content: content, in: root) }
        guard next != look else { return }
        look = next
        changed(next)
    }
}
