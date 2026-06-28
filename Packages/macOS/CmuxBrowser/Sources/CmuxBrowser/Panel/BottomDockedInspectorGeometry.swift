public import AppKit
public import WebKit

/// Infers the geometry of a web inspector docked at the bottom of a hosted
/// browser page and repairs the page `WKWebView` frame around it.
///
/// When WebKit docks the developer tools to the bottom of a hosted page, it can
/// leave the primary page `WKWebView`'s frame extending past the bottom of its
/// container instead of resting above the inspector. This type walks the live
/// container view tree to locate the inspector's frame, then computes the page
/// frame that should sit above it. It is the bottom-docked companion to
/// ``HostedInspectorDockSide``, which handles the left/right docked geometry.
///
/// The walk needs to recognize web-inspector views (`NSObject`'s
/// `isCmuxWebInspectorObject`). That predicate is injected as a closure so this
/// type stays decoupled from the detection seam, exactly as the
/// `WKWebView` rendering-state reattach lifecycle does. The methods read live
/// `NSView`/`WKWebView` geometry synchronously and hold no state beyond the
/// injected predicate, so callers construct one value at the call site and use
/// it for the inference and repair in a single main-actor turn.
///
/// `@MainActor`-isolated because every method reads live `NSView`/`WKWebView`
/// geometry, which is main-actor under Swift 6.1 (CI Xcode 16.4). Local Swift 6.3
/// accepted the nonisolated reads; the isolation is the faithful contract.
@MainActor
public struct BottomDockedInspectorGeometry {
    /// Recognizes a web-inspector view. Supplied by the caller (typically
    /// `NSObject.isCmuxWebInspectorObject`) so this type stays decoupled from the
    /// inspector-detection seam.
    public let isWebInspectorObject: (NSView) -> Bool

    /// Creates an inference value over the supplied inspector predicate.
    /// - Parameter isWebInspectorObject: returns whether a view is a
    ///   web-inspector view (e.g. a `WKInspector`/`WebInspector` instance).
    public init(isWebInspectorObject: @escaping (NSView) -> Bool) {
        self.isWebInspectorObject = isWebInspectorObject
    }

    /// Whether `root` has any visible web-inspector view in its subtree
    /// (excluding `root` itself), where visible means not hidden, non-zero
    /// alpha, and larger than one point in both dimensions.
    public func hasVisibleInspectorDescendant(in root: NSView) -> Bool {
        var stack: [NSView] = [root]
        while let current = stack.popLast() {
            if current !== root {
                if isWebInspectorObject(current),
                   !current.isHidden,
                   current.alphaValue > 0,
                   current.frame.width > 1,
                   current.frame.height > 1 {
                    return true
                }
            }
            stack.append(contentsOf: current.subviews)
        }
        return false
    }

    /// Infers the frame of a bottom-docked inspector inside `containerView`.
    ///
    /// Considers each sibling of `primaryWebView` that contains a visible
    /// inspector descendant, horizontally overlaps the page by more than 70%,
    /// is pinned to the container's bottom edge, and sits below the page's
    /// bottom edge. Returns the tallest such frame, or `nil` when none qualifies.
    ///
    /// - Parameters:
    ///   - containerView: the view hosting the page and inspector.
    ///   - primaryWebView: the page web view the inspector is docked beneath.
    ///   - epsilon: tolerance for the bottom-edge alignment checks. Defaults to `1`.
    public func inferredBottomDockedInspectorFrame(
        in containerView: NSView,
        primaryWebView: WKWebView,
        epsilon: CGFloat = 1
    ) -> NSRect? {
        let pageFrame = primaryWebView.frame
        let containerBounds = containerView.bounds

        let candidates = containerView.subviews.compactMap { candidate -> NSRect? in
            guard candidate !== primaryWebView else { return nil }
            guard hasVisibleInspectorDescendant(in: candidate) else { return nil }

            let frame = candidate.frame
            guard frame.width > 1, frame.height > 1 else { return nil }
            let overlapWidth = min(pageFrame.maxX, frame.maxX) - max(pageFrame.minX, frame.minX)
            guard overlapWidth > min(pageFrame.width, frame.width) * 0.7 else { return nil }
            guard frame.minY <= containerBounds.minY + epsilon else { return nil }
            guard frame.maxY <= pageFrame.minY + epsilon else { return nil }
            return frame
        }

        return candidates.max(by: { $0.height < $1.height })
    }

    /// The page `WKWebView` frame that should sit above a bottom-docked
    /// inspector, or `nil` when no repair is needed.
    ///
    /// Returns `nil` unless the page frame currently extends outside the
    /// container bounds and a bottom-docked inspector frame can be inferred. The
    /// repaired frame spans the container width and the height from the
    /// inspector's top edge to the container's top edge.
    ///
    /// - Parameters:
    ///   - containerView: the view hosting the page and inspector.
    ///   - primaryWebView: the page web view to compute a repaired frame for.
    ///   - epsilon: tolerance for the overflow check. Defaults to `0.5`.
    public func repairedBottomDockedPageFrame(
        in containerView: NSView,
        primaryWebView: WKWebView,
        epsilon: CGFloat = 0.5
    ) -> NSRect? {
        let pageFrame = primaryWebView.frame
        let containerBounds = containerView.bounds
        guard pageFrame.extendsOutside(containerBounds, epsilon: epsilon),
              let inspectorFrame = inferredBottomDockedInspectorFrame(
                  in: containerView,
                  primaryWebView: primaryWebView
              ) else {
            return nil
        }

        return NSRect(
            x: containerBounds.minX,
            y: inspectorFrame.maxY,
            width: containerBounds.width,
            height: max(0, containerBounds.maxY - inspectorFrame.maxY)
        )
    }
}
