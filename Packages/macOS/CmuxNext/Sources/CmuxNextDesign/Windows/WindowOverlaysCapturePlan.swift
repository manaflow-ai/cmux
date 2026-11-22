public import CoreGraphics

/// What a window's composite with its overlays takes (``NSWindow/compositedImageWithOverlays(cuttingOverlays:capture:)``),
/// read from AppKit on the main actor: window numbers, levels and the frame only, so the window server calls (its
/// window list and composites), the blank checks and the overlay mask run on any thread.
public nonisolated struct WindowOverlaysCapturePlan: Sendable, Hashable {
    /// The window.
    let window: Int
    /// Its visible child windows, composited with it.
    let children: [Int]
    /// The child windows whose overlays are cut from the composite; nil: no cut.
    let cutChildren: [Int]?
    /// The app's windows over it (menus, cards, popovers not its children); nil when it is not on the active space.
    let floating: FloatingWindowsCapturePlan?
    /// Its capture backdrop, composited behind everything.
    let backdrop: Int?
    /// The window's frame in global display coordinates, the crop of a composite; nil without a screen.
    let rect: CGRect?
}

/// A window's composite with its overlays (``NSWindow/compositedImageWithOverlays(cuttingOverlays:capture:)``).
public nonisolated struct WindowOverlaysCapture: Sendable {
    /// The window, its child windows and the app's windows over it, composited together.
    public let image: CGImage
    /// How many of the app's windows over it the image includes.
    public let floating: Int
    /// The overlays cut from ``image`` when the plan cuts them, transparent elsewhere; nil without any.
    public let overlays: CGImage?

    public init(image: CGImage, floating: Int, overlays: CGImage?) {
        self.image = image
        self.floating = floating
        self.overlays = overlays
    }
}
