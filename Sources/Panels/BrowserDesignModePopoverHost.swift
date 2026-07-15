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
struct BrowserDesignModePopoverHost: View {
    private static let hostCoordinateSpace = "cmuxDesignModeComposerHost"

    @Bindable var controller: BrowserDesignModeController
    var onCardFrameChange: (CGRect) -> Void = { _ in }

    var body: some View {
        ZStack {
            if controller.isComposerPresented {
                BrowserDesignModePopover(controller: controller)
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named(Self.hostCoordinateSpace))
                    } action: { frame in
                        onCardFrameChange(frame)
                    }
                    .padding(.bottom, 14)
                    .transition(
                        .opacity.combined(with: .move(edge: .bottom)).combined(with: .scale(scale: 0.98, anchor: .bottom))
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .coordinateSpace(.named(Self.hostCoordinateSpace))
        .animation(.spring(duration: 0.2), value: controller.isComposerPresented)
        .onChange(of: controller.isComposerPresented) { _, presented in
            if !presented { onCardFrameChange(.zero) }
        }
    }
}
