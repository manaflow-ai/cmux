import AppKit
import CmuxFoundation
import Observation
import CmuxSidebar
import SwiftUI

/// Owns a mode bar tab drag. Inside the bar the real tab follows the pointer
/// and the others glide aside (`RightSidebarModeBarDragLayout`); the order is
/// saved once, on release, and the dragged tab springs from where it is into
/// its slot. Carried out of the bar, the tab hands off to a native drag so it
/// can still open as a pane, and the bar settles back.
@MainActor
@Observable
final class RightSidebarModeBarDragController {
    nonisolated static let coordinateSpace = "RightSidebarModeBarTabs"
    /// A longer, nearly critically damped spring keeps lateral tab movement
    /// gradual while staying responsive when the order changes.
    static let spring = Animation.spring(response: 0.34, dampingFraction: 0.9)

    struct Session {
        let mode: RightSidebarMode
        let modes: [RightSidebarMode]
        let layout: RightSidebarModeBarDragLayout
        /// Identifies the gesture: a new press starts a new session.
        let startLocation: CGPoint
        var slot: Int
        var offsets: [CGFloat]
        /// The tab left the bar and a native drag carries it.
        var isCarriedOut = false
    }

    private(set) var session: Session?
    /// The pointer's horizontal travel. Kept apart from `session` so the
    /// dragged tab tracks the pointer without animation while the slot
    /// changes animate.
    private(set) var translation: CGFloat = 0

    /// Every tab's frame in `coordinateSpace`, frozen into a session at drag start.
    @ObservationIgnored var frames: [RightSidebarMode: CGRect] = [:]
    let anchor = RightSidebarModeBarDragAnchor()
    @ObservationIgnored private var paneDrag: RightSidebarModePaneDragSource?
    @ObservationIgnored private var mouseUpMonitor: Any?
    /// The gesture that last ended. SwiftUI can deliver one more change for
    /// it after the release; that must not start a new drag.
    @ObservationIgnored private var endedStartLocation: CGPoint?

    func isLifted(_ mode: RightSidebarMode) -> Bool {
        guard let session else { return false }
        return session.mode == mode && !session.isCarriedOut
    }

    func offset(for mode: RightSidebarMode) -> CGFloat {
        guard let session, let index = session.modes.firstIndex(of: mode) else { return 0 }
        if isLifted(mode) { return session.layout.draggedOffset(translation: translation) }
        return session.offsets[index]
    }

    func changed(
        mode: RightSidebarMode,
        displayed: [RightSidebarMode],
        startLocation: CGPoint,
        location: CGPoint,
        translation travel: CGSize,
        barHeight: CGFloat,
        animation: Animation?,
        dragImage: @MainActor (CGSize) -> NSImage?
    ) {
        if session?.mode != mode || session?.startLocation != startLocation {
            guard startLocation != endedStartLocation, begin(mode: mode, displayed: displayed, startLocation: startLocation) else { return }
        }
        guard var current = session, !current.isCarriedOut else { return }
        let tabFrame = current.layout.frames[current.layout.source]
        if mode.canOpenAsPane,
           RightSidebarModeBarDragLayout.leavesBar(pointer: location, tabFrame: tabFrame, barHeight: barHeight),
           carryOut(current, tabFrame: tabFrame, travel: travel, animation: animation, dragImage: dragImage) {
            return
        }
        translation = travel.width
        let slot = current.layout.slot(translation: translation)
        guard slot != current.slot else { return }
        current.slot = slot
        current.offsets = current.layout.offsets(slot: slot)
        withAnimation(animation) { session = current }
    }

    /// Saves the order the bar shows and lets every tab settle in one
    /// transaction, so the dropped tab glides from the pointer into its slot.
    func ended(mode: RightSidebarMode, startLocation: CGPoint, animation: Animation?) {
        guard let current = session, current.mode == mode, current.startLocation == startLocation else { return }
        commit(current, animation: animation)
    }

    private func begin(mode: RightSidebarMode, displayed: [RightSidebarMode], startLocation: CGPoint) -> Bool {
        // A newer press proves AppKit has left any earlier carried-out drag.
        paneDrag?.finish()
        removeMouseUpMonitor()
        let frames = displayed.compactMap { self.frames[$0] }
        guard frames.count == displayed.count,
              let source = displayed.firstIndex(of: mode),
              let layout = RightSidebarModeBarDragLayout(frames: frames, source: source) else {
            session = nil
            return false
        }
        translation = 0
        session = Session(
            mode: mode, modes: displayed, layout: layout, startLocation: startLocation,
            slot: source, offsets: Array(repeating: 0, count: displayed.count)
        )
        // SwiftUI can drop a drag's end (the gesture is cancelled, or the
        // release lands outside the window). The release itself always comes
        // through the app, so it ends the session too.
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, let current = self.session, !current.isCarriedOut {
                    self.commit(current, animation: self.lastAnimation)
                }
            }
            return event
        }
        return true
    }

    /// The animation of the latest gesture update, for the release monitor.
    @ObservationIgnored private var lastAnimation: Animation? = RightSidebarModeBarDragController.spring

    private func commit(_ current: Session, animation: Animation?) {
        removeMouseUpMonitor()
        endedStartLocation = current.startLocation
        guard !current.isCarriedOut else { return }
        let order = current.layout.reordered(current.modes, slot: current.slot)
        withAnimation(animation) {
            // The bar reads the saved order in the same update that clears
            // the offsets, so position and offset animate together.
            if order != current.modes {
                RightSidebarTabPreferences.setDisplayedOrder(order)
            }
            session = nil
            translation = 0
        }
    }

    private func carryOut(
        _ current: Session,
        tabFrame: CGRect,
        travel: CGSize,
        animation: Animation?,
        dragImage: @MainActor (CGSize) -> NSImage?
    ) -> Bool {
        guard let view = anchor.view,
              let event = NSApp.currentEvent, event.type == .leftMouseDragged,
              let image = dragImage(tabFrame.size) else { return false }
        let frame = tabFrame.offsetBy(dx: current.layout.draggedOffset(translation: translation), dy: travel.height)
        guard let source = RightSidebarModeDragPayload.beginPaneDrag(
            mode: current.mode, from: view, event: event, frame: frame, image: image,
            onEnd: { [weak self] in self?.paneDragEnded() }
        ) else { return false }
        removeMouseUpMonitor()
        paneDrag = source
        var next = current
        next.isCarriedOut = true
        next.slot = current.layout.source
        next.offsets = Array(repeating: 0, count: current.modes.count)
        withAnimation(animation) {
            session = next
            translation = 0
        }
        return true
    }

    private func paneDragEnded() {
        paneDrag = nil
        if session?.isCarriedOut == true {
            endedStartLocation = session?.startLocation
            session = nil
        }
    }

    private func removeMouseUpMonitor() {
        if let mouseUpMonitor { NSEvent.removeMonitor(mouseUpMonitor) }
        mouseUpMonitor = nil
    }

    fileprivate func noteAnimation(_ animation: Animation?) {
        lastAnimation = animation
    }
}

/// The view a carried-out tab's native drag starts from: the tab row's
/// background, flipped so its coordinates match `coordinateSpace`.
@MainActor
final class RightSidebarModeBarDragAnchor {
    weak var view: NSView?
}

struct RightSidebarModeBarDragAnchorView: NSViewRepresentable {
    let anchor: RightSidebarModeBarDragAnchor

    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }

    private final class AnchorView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Makes one mode bar tab draggable along the bar and out of it.
struct RightSidebarModeBarTabDrag: ViewModifier {
    let mode: RightSidebarMode
    let displayedModes: [RightSidebarMode]
    let barHeight: CGFloat
    let controller: RightSidebarModeBarDragController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var animation: Animation? { reduceMotion ? nil : RightSidebarModeBarDragController.spring }

    func body(content: Content) -> some View {
        let lifted = controller.isLifted(mode)
        content
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(RightSidebarModeBarDragController.coordinateSpace))
            } action: { frame in
                // Measured inside the offset; keep the tab's resting frame so
                // a drag that starts mid-glide freezes the real slots.
                controller.frames[mode] = frame.offsetBy(dx: -controller.offset(for: mode), dy: 0)
            }
            .offset(x: controller.offset(for: mode))
            // The lifted tab is under the hand: it never animates while held.
            .transaction { transaction in
                if lifted { transaction.animation = nil }
            }
            .zIndex(lifted ? 1 : 0)
            .highPriorityGesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .named(RightSidebarModeBarDragController.coordinateSpace))
                    .onChanged { value in
                        controller.noteAnimation(animation)
                        controller.changed(
                            mode: mode, displayed: displayedModes,
                            startLocation: value.startLocation, location: value.location,
                            translation: value.translation, barHeight: barHeight,
                            animation: animation, dragImage: dragImage
                        )
                    }
                    .onEnded { value in
                        controller.ended(mode: mode, startLocation: value.startLocation, animation: animation)
                    }
            )
    }

    @MainActor
    private func dragImage(size: CGSize) -> NSImage? {
        let renderer = ImageRenderer(
            content: RightSidebarModeBarDragPreview(mode: mode)
                // Keep the preview at its intrinsic width. The resting tab
                // can be narrower while the drag image must retain the full label.
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: size.width, minHeight: size.height)
                .environment(\.colorScheme, colorScheme)
        )
        renderer.scale = controller.anchor.view?.window?.backingScaleFactor ?? 2
        return renderer.nsImage
    }
}

/// The tab as it looks selected, for the image a carried-out drag shows.
private struct RightSidebarModeBarDragPreview: View {
    let mode: RightSidebarMode
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var globalFontPercent

    var body: some View {
        HStack(spacing: 4) {
            // ImageRenderer cannot capture the NSViewRepresentable used by
            // CmuxSystemSymbolImage. Supply its materialized bitmap instead.
            if let image = RenderableSystemSymbol.configuredAppKitImage(
                systemName: mode.symbolName,
                pointSize: GlobalFontMagnification.scaledSize(
                    RightSidebarChromeControlStyle.modeIconSize, percent: globalFontPercent
                ),
                weight: RightSidebarChromeControlStyle.iconWeight
            ) {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .foregroundStyle(RightSidebarChromeControlStyle.pillForegroundColor(isSelected: true, isHovered: true))
            }
            Text(mode.label)
                .cmuxFont(size: RightSidebarChromeControlStyle.labelSize, weight: RightSidebarChromeControlStyle.labelWeight)
                .lineLimit(1)
        }
        .rightSidebarChromePill(isSelected: true, isHovered: true)
    }
}
