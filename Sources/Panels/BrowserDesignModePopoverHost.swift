import AppKit
import CmuxBrowser
import SwiftUI

/// Hosts the Design Mode composer overlay above the portal-hosted WKWebView.
///
/// A plain `NSHostingView` claims every point in `hitTest`, so a full-slot
/// overlay would swallow clicks, scrolls, and element-picker interactions
/// meant for the page — even while the composer card is dismissed, and, while
/// it is presented, everywhere outside the card (multi-select requires page
/// clicks while the card stays open). Events are routed only within the card
/// frame reported by `BrowserDesignModePopoverHost`; everything else passes
/// through to the web content below. Same pattern as
/// `BrowserPortalOmnibarSuggestionsHostingView`.
final class BrowserDesignModeComposerHostingView: NSHostingView<BrowserDesignModePopoverHost> {
    var cardFrameInTopLeftCoordinates: CGRect = .zero {
        didSet {
            guard oldValue != cardFrameInTopLeftCoordinates else { return }
            window?.invalidateCursorRects(for: self)
        }
    }
    /// Fired while the pointer moves within the card. SwiftUI's onHover does
    /// not fire reliably over the embedded AppKit token text view, so the
    /// page-side hover clear is driven from this tracking area instead.
    var onPointerInsideCard: (() -> Void)?
    /// Native card dragging: translation in top-left coordinates while a
    /// drag that began on the card (outside the text editor) is active,
    /// then nil on end. SwiftUI gestures cannot own this because the AppKit
    /// editor consumes events over most of the card.
    var onCardDrag: ((CGSize?) -> Void)?
    private var cardTrackingArea: NSTrackingArea?
    private var cardDragStartInWindow: NSPoint?
    private var cardDragActive = false
#if DEBUG
    private static var lastHitTestRejectLogAt: CFTimeInterval = 0
#endif

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cardTrackingArea { removeTrackingArea(cardTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        cardTrackingArea = area
    }

    override func mouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        let topLeftPoint = isFlipped
            ? localPoint
            : NSPoint(x: localPoint.x, y: bounds.height - localPoint.y)
#if DEBUG
        cmuxDebugLog(
            "designMode.card.mouseDown local=\(Int(localPoint.x)),\(Int(localPoint.y)) " +
            "topLeft=\(Int(topLeftPoint.x)),\(Int(topLeftPoint.y)) " +
            "card=\(Int(cardFrameInTopLeftCoordinates.minX)),\(Int(cardFrameInTopLeftCoordinates.minY)) " +
            "\(Int(cardFrameInTopLeftCoordinates.width))x\(Int(cardFrameInTopLeftCoordinates.height)) " +
            "flipped=\(isFlipped ? 1 : 0) bounds=\(Int(bounds.width))x\(Int(bounds.height))"
        )
#endif
        if cardFrameInTopLeftCoordinates.contains(topLeftPoint), !pointIsInTextEditor(localPoint) {
            cardDragStartInWindow = event.locationInWindow
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if let start = cardDragStartInWindow {
            let dx = event.locationInWindow.x - start.x
            let dy = start.y - event.locationInWindow.y
            if cardDragActive || abs(dx) > 3 || abs(dy) > 3 {
                cardDragActive = true
                onCardDrag?(CGSize(width: dx, height: dy))
            }
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if cardDragActive {
            onCardDrag?(nil)
        }
        cardDragStartInWindow = nil
        cardDragActive = false
        super.mouseUp(with: event)
    }

    /// The prompt editor keeps its own drag behavior (text selection); card
    /// drags start anywhere else on the card.
    private func pointIsInTextEditor(_ localPoint: NSPoint) -> Bool {
        var stack: [NSView] = subviews
        while let view = stack.popLast() {
            if view is NSScrollView || view is NSTextView {
                if let container = view.superview {
                    let converted = convert(localPoint, to: container)
                    if view.frame.contains(converted) { return true }
                }
            }
            stack.append(contentsOf: view.subviews)
        }
        return false
    }

    override func mouseMoved(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        let topLeftPoint = isFlipped
            ? localPoint
            : NSPoint(x: localPoint.x, y: bounds.height - localPoint.y)
        if cardFrameInTopLeftCoordinates.contains(topLeftPoint) {
            onPointerInsideCard?()
        }
        super.mouseMoved(with: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // AppKit passes hit-test points in the superview's coordinate space.
        // Compare the card frame in this hosting view's own top-left local
        // space so offset overlays and flipped hosting views route consistently.
        guard let superview else { return nil }
        let localPoint = convert(point, from: superview)
        let topLeftPoint = isFlipped
            ? localPoint
            : NSPoint(x: localPoint.x, y: bounds.height - localPoint.y)
        guard cardFrameInTopLeftCoordinates.contains(topLeftPoint) else {
#if DEBUG
            let now = CACurrentMediaTime()
            if now - Self.lastHitTestRejectLogAt > 1.0 {
                Self.lastHitTestRejectLogAt = now
                cmuxDebugLog(
                    "designMode.card.hitTest.reject topLeft=\(Int(topLeftPoint.x)),\(Int(topLeftPoint.y)) " +
                    "card=\(Int(cardFrameInTopLeftCoordinates.minX)),\(Int(cardFrameInTopLeftCoordinates.minY)) " +
                    "\(Int(cardFrameInTopLeftCoordinates.width))x\(Int(cardFrameInTopLeftCoordinates.height)) " +
                    "flipped=\(isFlipped ? 1 : 0) bounds=\(Int(bounds.width))x\(Int(bounds.height))"
                )
            }
#endif
            return nil
        }
        // hitTest runs for every event over the card — the one place the
        // pointer provably sits on the composer — so the page-side hover
        // clear hooks here (tracking-area mouseMoved alone proved unreliable
        // over the embedded text view).
        onPointerInsideCard?()
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        // The page shield advertises a crosshair; the composer must not.
        // Deeper views (the token text view) still override with I-beam.
        let cardRect = isFlipped
            ? cardFrameInTopLeftCoordinates
            : NSRect(
                x: cardFrameInTopLeftCoordinates.minX,
                y: bounds.height - cardFrameInTopLeftCoordinates.maxY,
                width: cardFrameInTopLeftCoordinates.width,
                height: cardFrameInTopLeftCoordinates.height
            )
        addCursorRect(cardRect, cursor: .arrow)
    }
}

/// Relays native card drags from the AppKit hosting view into the SwiftUI
/// placement state (translation while dragging, nil on end).
@MainActor
final class BrowserDesignModeCardDragBridge: ObservableObject {
    @Published var translation: CGSize?
}

/// Presents the Design Mode composer as a floating card over the browser panel.
///
/// The card anchors bottom-center until the user drags it; dragging moves the
/// card through real layout (leading/top padding), so the frame reported to
/// the hosting view's hit-test shield always matches what is on screen.
struct BrowserDesignModePopoverHost: View {
    private static let hostCoordinateSpace = "cmuxDesignModeComposerHost"
    private static let edgeInset: CGFloat = 8

    @Bindable var controller: BrowserDesignModeController
    @ObservedObject var dragBridge = BrowserDesignModeCardDragBridge()
    var onCardFrameChange: (CGRect) -> Void = { _ in }

    @State private var cardFrame: CGRect = .zero
    /// Top-leading origin of the card. Set automatically next to the active
    /// selection (Cursor-style) and overridden by manual dragging; nil falls
    /// back to the docked bottom-center position.
    @State private var cardOrigin: CGPoint?
    @State private var dragStartOrigin: CGPoint?

    /// Identity + geometry of the active (last) selection, used to reposition
    /// the card whenever the user selects a different element.
    private struct SelectionAnchor: Equatable {
        var selector: String
        var bounds: BrowserDesignModeRect
    }

    private var activeAnchor: SelectionAnchor? {
        guard let selection = controller.snapshot?.selections.last else { return nil }
        return SelectionAnchor(selector: selection.selector, bounds: selection.bounds)
    }

    var body: some View {
        GeometryReader { host in
            ZStack(alignment: cardOrigin == nil ? .bottom : .topLeading) {
                if controller.isComposerPresented {
                    BrowserDesignModePopover(controller: controller)
                        .onGeometryChange(for: CGRect.self) { proxy in
                            proxy.frame(in: .named(Self.hostCoordinateSpace))
                        } action: { frame in
                            cardFrame = frame
                            onCardFrameChange(frame)
                        }
                        .padding(.leading, cardOrigin?.x ?? 0)
                        .padding(.top, cardOrigin?.y ?? 0)
                        .padding(.bottom, cardOrigin == nil ? 14 : 0)
                        // Simultaneous: the AppKit prompt editor consumes
                        // drags over the text, so the card must be draggable
                        // from every SwiftUI-owned region (mode toggle, copy
                        // button, paddings/edges) without breaking their taps.
                        .simultaneousGesture(dragGesture(hostSize: host.size))
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: cardOrigin == nil ? .bottom : .topLeading)
            .onChange(of: dragBridge.translation) { _, translation in
                // Native card drags from the hosting view use the same
                // clamped placement math as the SwiftUI gesture.
                guard let translation else {
                    dragStartOrigin = nil
                    return
                }
                let start = dragStartOrigin ?? cardFrame.origin
                dragStartOrigin = start
                cardOrigin = CGPoint(
                    x: min(max(start.x + translation.width, Self.edgeInset),
                           max(Self.edgeInset, host.size.width - cardFrame.width - Self.edgeInset)),
                    y: min(max(start.y + translation.height, Self.edgeInset),
                           max(Self.edgeInset, host.size.height - cardFrame.height - Self.edgeInset))
                )
            }
            .onChange(of: activeAnchor) { _, anchor in
                // Follow each new selection unless the user is mid-drag.
                guard let anchor, dragStartOrigin == nil else { return }
                cardOrigin = origin(near: anchor.bounds, hostSize: host.size)
            }
        }
        .coordinateSpace(.named(Self.hostCoordinateSpace))
        .animation(.spring(duration: 0.2), value: controller.isComposerPresented)
        .animation(dragStartOrigin == nil ? .spring(duration: 0.25) : nil, value: cardOrigin)
        .onChange(of: controller.isComposerPresented) { _, presented in
            if !presented {
                cardOrigin = nil
                dragStartOrigin = nil
                onCardFrameChange(.zero)
            }
        }
    }

    /// Places the card centered under the element, flipping above it when
    /// there is no room below, clamped to the pane.
    private func origin(near bounds: BrowserDesignModeRect, hostSize: CGSize) -> CGPoint {
        let cardWidth = cardFrame.width > 0 ? cardFrame.width : 420
        let cardHeight = cardFrame.height > 0 ? cardFrame.height : 46
        let gap: CGFloat = 10
        var x = CGFloat(bounds.x + bounds.width / 2) - cardWidth / 2
        x = min(max(x, Self.edgeInset), max(Self.edgeInset, hostSize.width - cardWidth - Self.edgeInset))
        var y = CGFloat(bounds.y + bounds.height) + gap
        if y + cardHeight > hostSize.height - Self.edgeInset {
            y = CGFloat(bounds.y) - cardHeight - gap
        }
        y = min(max(y, Self.edgeInset), max(Self.edgeInset, hostSize.height - cardHeight - Self.edgeInset))
        return CGPoint(x: x, y: y)
    }

    private func dragGesture(hostSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.hostCoordinateSpace))
            .onChanged { value in
                let start = dragStartOrigin ?? cardFrame.origin
                dragStartOrigin = start
                let proposed = CGPoint(
                    x: start.x + value.translation.width,
                    y: start.y + value.translation.height
                )
                cardOrigin = CGPoint(
                    x: min(max(proposed.x, Self.edgeInset), max(Self.edgeInset, hostSize.width - cardFrame.width - Self.edgeInset)),
                    y: min(max(proposed.y, Self.edgeInset), max(Self.edgeInset, hostSize.height - cardFrame.height - Self.edgeInset))
                )
            }
            .onEnded { _ in dragStartOrigin = nil }
    }
}
