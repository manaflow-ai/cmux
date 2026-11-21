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
        TooltipGallerySample(name: "Wraps past 320 pt",
                             text: "Shows the files this agent changed since your last message, grouped by folder, with their line counts",
                             shortcut: nil),
        TooltipGallerySample(name: "Wraps, with a shortcut",
                             text: "Opens the session in a new window beside this one, keeping its scroll position", shortcut: "⌥⌘N"),
        TooltipGallerySample(name: "Reduce Transparency", text: "New Tab", shortcut: "⌘T", opaque: true),
    ]
}
