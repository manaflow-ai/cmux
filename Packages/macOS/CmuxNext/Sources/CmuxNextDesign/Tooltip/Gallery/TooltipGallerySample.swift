import AppKit

/// One state the Tooltip Gallery draws (``TooltipGalleryWindow``): a tooltip's text, its keys and how its
/// surface draws. English developer text, as every playground's is.
struct TooltipGallerySample: Sendable {
    /// What the row is called in the gallery.
    let name: String
    let text: String
    let shortcut: String?
    /// Draws the Reduce Transparency surface (the opaque popup surface) instead of the glass.
    var opaque = false

    /// Every state, top to bottom.
    static let all: [TooltipGallerySample] = [
        TooltipGallerySample(name: "Text only", text: "Back", shortcut: nil),
        TooltipGallerySample(name: "With a shortcut", text: "New Tab", shortcut: "⌘T"),
        TooltipGallerySample(name: "Several keys", text: "Select effort", shortcut: "⌃⇧M"),
        // A tooltip is one line (a1315): a name too long for 320 pt ends in an ellipsis.
        TooltipGallerySample(name: "Too long for 320 pt",
                             text: "Open in New Window Beside This One, Keeping the Scroll Position and the Selection", shortcut: nil),
        TooltipGallerySample(name: "Too long, with a shortcut",
                             text: "Open in New Window Beside This One, Keeping the Scroll Position", shortcut: "⌥⌘N"),
        TooltipGallerySample(name: "Reduce Transparency", text: "New Tab", shortcut: "⌘T", opaque: true),
    ]
}
