public import CoreGraphics

/// Where the undocked DevTools window opens, in AppKit screen coordinates (bottom-left origin).
///
/// The window must not cover the page it inspects. A remembered frame wins (clamped onto the
/// screen); otherwise the window is as tall as the cmux window and `min(960, 45%)` of the screen's
/// visible width, beside the cmux window: right if it fits, else left, else cascaded 24 points
/// down and to the right over it.
///
/// ```swift
/// let frame = BrowserDevToolsWindowPlacement().frame(
///     owner: cmuxWindow.frame, visible: screen.visibleFrame, remembered: store.loadWindowFrame()
/// )
/// ```
public struct BrowserDevToolsWindowPlacement: Hashable, Sendable {
    /// The widest a first-time window gets.
    public static let maximumWidth: CGFloat = 960
    /// A first-time window's share of the screen's visible width.
    public static let widthShare: CGFloat = 0.45
    /// The offset of a cascaded window from the cmux window's top-left corner.
    public static let cascadeOffset: CGFloat = 24
    /// The smallest window, as the DevTools window's `minSize`.
    public static let minimumSize = CGSize(width: 360, height: 240)

    /// Creates a placement policy.
    public init() {}

    /// The window frame.
    /// - Parameters:
    ///   - owner: The cmux window's frame, or `nil` when the page shows in no window.
    ///   - visible: The visible frame of the screen the window opens on.
    ///   - remembered: The last frame the user left the window at, if any.
    /// - Returns: The frame, inside `visible`.
    public func frame(owner: CGRect?, visible: CGRect, remembered: CGRect?) -> CGRect {
        if let remembered, remembered.width >= Self.minimumSize.width, remembered.height >= Self.minimumSize.height {
            return clamp(remembered, to: visible)
        }
        let width = max(min(Self.maximumWidth, (visible.width * Self.widthShare).rounded()), Self.minimumSize.width)
        guard let owner else {
            let height = max(min(visible.height, 700), Self.minimumSize.height)
            return clamp(CGRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height), to: visible)
        }
        let height = max(min(owner.height, visible.height), Self.minimumSize.height)
        let y = owner.maxY - height
        if owner.maxX + width <= visible.maxX {
            return clamp(CGRect(x: owner.maxX, y: y, width: width, height: height), to: visible)
        }
        if owner.minX - width >= visible.minX {
            return clamp(CGRect(x: owner.minX - width, y: y, width: width, height: height), to: visible)
        }
        let cascaded = CGRect(
            x: owner.minX + Self.cascadeOffset,
            y: owner.maxY - Self.cascadeOffset - height,
            width: width, height: height
        )
        return clamp(cascaded, to: visible)
    }

    /// `rect` moved (and if needed shrunk) to lie inside `visible`.
    /// - Parameters:
    ///   - rect: A window frame.
    ///   - visible: The screen's visible frame.
    /// - Returns: The clamped frame.
    public func clamp(_ rect: CGRect, to visible: CGRect) -> CGRect {
        let width = min(rect.width, visible.width)
        let height = min(rect.height, visible.height)
        let x = min(max(rect.minX, visible.minX), visible.maxX - width)
        let y = min(max(rect.minY, visible.minY), visible.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
