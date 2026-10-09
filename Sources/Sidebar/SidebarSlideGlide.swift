import AppKit
import Bonsplit
import SwiftUI

/// Chrome inside the sliding content root that rests at a different x in
/// the docked and the hidden layout: the titlebar title (room for the
/// traffic lights and titlebar buttons when hidden, past the sidebar when
/// docked) and, in minimal mode, the first pane's tabs (room for the traffic
/// lights when hidden). The toggle's slide carries the content root
/// rigidly, so on its own such chrome would ride the slide with the hidden
/// layout's padding and snap at the landing. Each piece instead glides from
/// one resting x to the other in step with the spring, on the render server.
enum SidebarSlideGlide {
    /// The extra translation, per point of content offset, that takes chrome
    /// laid out at `hiddenLeading` (hidden layout, content offset 0) to
    /// `dockedLeading` (docked layout, offset 0) as the content offset runs
    /// from 0 to `sidebarWidth`. Linear in the offset, so one spring with the
    /// slide's parameters draws it exactly.
    static func factor(hiddenLeading: CGFloat, dockedLeading: CGFloat, sidebarWidth: CGFloat) -> Double {
        guard sidebarWidth > 0 else { return 0 }
        return Double((dockedLeading - hiddenLeading) / sidebarWidth - 1)
    }

    /// One layer the slide moves by `factor` points per point of content
    /// offset, on top of the content root's own translation.
    struct Layer {
        let layer: CALayer
        let keyPath: String
        let factor: Double
    }
}

extension ContentView {
    /// Where the titlebar title rests in the hidden and in the docked layout.
    /// Fullscreen and hidden, it also clears the always-visible titlebar
    /// controls (their width plus the row's 8 pt spacing).
    nonisolated static func titlebarTitleLeadings(
        isFullScreen: Bool,
        sidebarWidth: CGFloat,
        minimumSidebarWidth: CGFloat,
        titlebarLeadingInset: CGFloat,
        reservedControlsWidth: CGFloat
    ) -> (hidden: CGFloat, docked: CGFloat) {
        func padding(visible: Bool) -> CGFloat {
            customTitlebarLeadingPadding(
                isFullScreen: isFullScreen,
                isSidebarVisible: visible,
                sidebarWidth: sidebarWidth,
                minimumSidebarWidth: minimumSidebarWidth,
                titlebarLeadingInset: titlebarLeadingInset
            )
        }
        let reserved = isFullScreen ? reservedControlsWidth + 8 : 0
        return (padding(visible: false) + reserved, padding(visible: true))
    }
}

/// Hosts the titlebar title in its own layer so the toggle's slide can glide
/// it (`SidebarSlideGlide`). Clicks pass through to the titlebar's drag and
/// double-click surface except on AppKit views inside (the folder icon).
struct SidebarSlideGlideHost: NSViewRepresentable {
    /// Leading x of this view in the hidden and in the docked layout.
    let hiddenLeading: CGFloat
    let dockedLeading: CGFloat
    let layout: SidebarLayoutModel
    let content: AnyView

    final class ContainerView: NSView {
        let hostingView: NSHostingView<AnyView>
        fileprivate(set) var hiddenLeading: CGFloat = 0
        fileprivate(set) var dockedLeading: CGFloat = 0

        init(content: AnyView) {
            hostingView = NSHostingView(rootView: content)
            super.init(frame: .zero)
            wantsLayer = true
            hostingView.sizingOptions = []
            hostingView.autoresizingMask = [.width, .height]
            hostingView.frame = bounds
            addSubview(hostingView)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let hit = super.hitTest(point)
            return hit === self || hit === hostingView ? nil : hit
        }

        func glide(sidebarWidth: CGFloat) -> SidebarSlideGlide.Layer? {
            let factor = SidebarSlideGlide.factor(hiddenLeading: hiddenLeading, dockedLeading: dockedLeading, sidebarWidth: sidebarWidth)
            guard factor != 0, window != nil, let layer else { return nil }
            return SidebarSlideGlide.Layer(layer: layer, keyPath: "sublayerTransform.translation.x", factor: factor)
        }
    }

    func makeNSView(context: Context) -> ContainerView {
        let view = ContainerView(content: content)
        layout.titlebarTitle = view
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ContainerView, context: Context) {
        view.hiddenLeading = hiddenLeading
        view.dockedLeading = dockedLeading
        view.hostingView.rootView = content
    }
}

/// Minimal mode's first-pane tabs, carried through a slide as a picture.
///
/// The tabs live in Bonsplit's SwiftUI tree, which has no layer of their
/// own to move. So the slide takes a picture of them at the press, lays it
/// over a stretch of plain tab bar that hides the real tabs, and glides the
/// picture by the inset in step with the spring. Both go when the slide
/// lands, in the same commit that applies the landed layout's inset.
@MainActor
struct SidebarSlideTabRowCapture {
    let picture: CGImage
    let ground: CGImage
    /// Where the plain ground and the picture sit, in the content root's
    /// coordinates under the hidden layout.
    let groundRect: NSRect
    let pictureRect: NSRect
    let factor: Double

    /// `docked` is the layout on screen now: true for a hide's press (taken
    /// before the hidden layout commits), false for a show's.
    static func capture(in reference: NSView, docked: Bool, inset: CGFloat, sidebarWidth: CGFloat) -> Self? {
        guard inset > 0, sidebarWidth > 0 else { return nil }
        var regions: [(pane: NSView, rect: NSRect)] = []
        func walk(_ view: NSView) {
            if view is BonsplitTabItemHitRegionProviding, !view.isHiddenOrHasHiddenAncestor,
               !view.visibleRect.isEmpty, let pane = paneHost(of: view) {
                regions.append((pane, reference.convert(view.visibleRect, from: view)))
            }
            view.subviews.forEach(walk)
        }
        walk(reference)
        // The inset belongs to the leading, topmost pane.
        let flipped = reference.isFlipped
        func paneRect(_ pane: NSView) -> NSRect { reference.convert(pane.bounds, from: pane) }
        guard let pane = regions.map(\.pane).min(by: { lhs, rhs in
            let l = paneRect(lhs), r = paneRect(rhs)
            if abs(l.minX - r.minX) > 0.5 { return l.minX < r.minX }
            return flipped ? l.minY < r.minY : l.maxY > r.maxY
        }) else { return nil }
        let paneFrame = paneRect(pane)
        let rects = regions.filter { $0.pane === pane }.map(\.rect)
        guard var tabs = rects.first else { return nil }
        rects.dropFirst().forEach { tabs = tabs.union($0) }
        let trailing = min(paneFrame.maxX, splitButtonsMinX(in: pane, reference: reference) ?? paneFrame.maxX)
        tabs.size.width = min(tabs.width, trailing - tabs.minX)
        guard tabs.width > 1, tabs.height > 1 else { return nil }
        // A column of plain tab bar: inside the inset strip when hidden,
        // past the last tab when docked.
        let groundX = docked ? min(tabs.maxX + 1, trailing - 1) : min(paneFrame.minX + 1, tabs.minX - 1)
        guard let picture = snapshot(reference, tabs),
              let ground = snapshot(reference, NSRect(x: groundX, y: tabs.minY, width: 1, height: tabs.height)) else {
            return nil
        }
        // Docked, the hidden layout moves the pane by the sidebar width and
        // its tabs by the sidebar width less the inset.
        let paneShift = docked ? -sidebarWidth : 0
        let tabsShift = docked ? inset - sidebarWidth : 0
        return Self(
            picture: picture,
            ground: ground,
            groundRect: NSRect(x: paneFrame.minX + paneShift, y: tabs.minY, width: trailing - paneFrame.minX - paneShift, height: tabs.height),
            pictureRect: tabs.offsetBy(dx: tabsShift, dy: 0),
            // Hidden, the tabs rest `inset` past the pane; docked, at the
            // pane, which the docked layout puts a sidebar width further on.
            factor: SidebarSlideGlide.factor(hiddenLeading: inset, dockedLeading: sidebarWidth, sidebarWidth: sidebarWidth)
        )
    }

    private static func paneHost(of view: NSView) -> NSView? {
        var current = view.superview
        while let candidate = current {
            if NSStringFromClass(type(of: candidate)).contains("NonDraggableHostingView") { return candidate }
            current = candidate.superview
        }
        return nil
    }

    private static func splitButtonsMinX(in pane: NSView, reference: NSView) -> CGFloat? {
        var xs: [CGFloat] = []
        func walk(_ view: NSView) {
            if NSStringFromClass(type(of: view)).contains("SplitActionMouseDown"), !view.isHiddenOrHasHiddenAncestor {
                xs.append(reference.convert(view.bounds, from: view).minX)
            }
            view.subviews.forEach(walk)
        }
        walk(pane)
        return xs.min()
    }

    private static func snapshot(_ view: NSView, _ rect: NSRect) -> CGImage? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        view.cacheDisplay(in: rect, to: rep)
        return rep.cgImage
    }

    /// The overlay the slide moves with the content root, and the picture
    /// layer inside it that glides on top of that.
    func makeOverlay(above reference: NSView, in container: NSView) -> (view: NSView, glide: SidebarSlideGlide.Layer)? {
        let view = PassthroughView(frame: container.convert(groundRect, from: reference))
        view.wantsLayer = true
        container.addSubview(view, positioned: .above, relativeTo: reference)
        guard let layer = view.layer else {
            view.removeFromSuperview()
            return nil
        }
        layer.contents = ground
        layer.contentsGravity = .resize
        let pictureLayer = CALayer()
        pictureLayer.contents = picture
        pictureLayer.contentsGravity = .resize
        pictureLayer.frame = view.convert(pictureRect, from: reference)
        layer.addSublayer(pictureLayer)
        return (view, SidebarSlideGlide.Layer(layer: pictureLayer, keyPath: "transform.translation.x", factor: factor))
    }

    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
