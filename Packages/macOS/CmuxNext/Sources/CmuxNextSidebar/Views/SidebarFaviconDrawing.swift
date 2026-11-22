import AppKit

/// A favicon as one surface draws it (`SidebarFaviconRenditions.drawing`): the image to hand the image view and how
/// it was treated. A template image takes its ink from the image view's `contentTintColor` (the surface's label colour).
struct SidebarFaviconDrawing {
    /// The image, `side` points square, its bitmap made once and kept.
    let image: NSImage
    /// How the favicon was treated (`SidebarFaviconStyle.treatment`).
    let treatment: SidebarFaviconTreatment
    /// Pixels on a side of the bitmap behind `image`.
    let pixels: Int

    /// Whether the image is a template the image view tints.
    var isTemplate: Bool { treatment == .template }
}
