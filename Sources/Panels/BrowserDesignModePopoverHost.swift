import AppKit
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
    var cardFrameInTopLeftCoordinates: CGRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        // AppKit passes hit-test points in the superview's coordinate space.
        // Compare the card frame in this hosting view's own top-left local
        // space so offset overlays and flipped hosting views route consistently.
        guard let superview else { return nil }
        let localPoint = convert(point, from: superview)
        let topLeftPoint = isFlipped
            ? localPoint
            : NSPoint(x: localPoint.x, y: bounds.height - localPoint.y)
        guard cardFrameInTopLeftCoordinates.contains(topLeftPoint) else { return nil }
        return super.hitTest(point)
    }
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
    var onCardFrameChange: (CGRect) -> Void = { _ in }

    @State private var cardFrame: CGRect = .zero
    /// Top-leading origin of the card once the user has dragged it; nil while
    /// still anchored to the default bottom-center position.
    @State private var draggedOrigin: CGPoint?
    @State private var dragStartOrigin: CGPoint?

    var body: some View {
        GeometryReader { host in
            ZStack(alignment: draggedOrigin == nil ? .bottom : .topLeading) {
                if controller.isComposerPresented {
                    BrowserDesignModePopover(controller: controller)
                        .onGeometryChange(for: CGRect.self) { proxy in
                            proxy.frame(in: .named(Self.hostCoordinateSpace))
                        } action: { frame in
                            cardFrame = frame
                            onCardFrameChange(frame)
                        }
                        .padding(.leading, draggedOrigin?.x ?? 0)
                        .padding(.top, draggedOrigin?.y ?? 0)
                        .padding(.bottom, draggedOrigin == nil ? 14 : 0)
                        .gesture(dragGesture(hostSize: host.size))
                        .transition(
                            .opacity.combined(with: .move(edge: .bottom)).combined(with: .scale(scale: 0.98, anchor: .bottom))
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: draggedOrigin == nil ? .bottom : .topLeading)
        }
        .coordinateSpace(.named(Self.hostCoordinateSpace))
        .animation(.spring(duration: 0.2), value: controller.isComposerPresented)
        .onChange(of: controller.isComposerPresented) { _, presented in
            if !presented {
                draggedOrigin = nil
                dragStartOrigin = nil
                onCardFrameChange(.zero)
            }
        }
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
                draggedOrigin = CGPoint(
                    x: min(max(proposed.x, Self.edgeInset), max(Self.edgeInset, hostSize.width - cardFrame.width - Self.edgeInset)),
                    y: min(max(proposed.y, Self.edgeInset), max(Self.edgeInset, hostSize.height - cardFrame.height - Self.edgeInset))
                )
            }
            .onEnded { _ in dragStartOrigin = nil }
    }
}
