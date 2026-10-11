/// The window material cmux.json names in `appearance.backgroundBlur`,
/// overriding the material Ghostty's `background-blur` gives.
public nonisolated enum WindowMaterialChoice: String, CaseIterable, Hashable, Sendable {
    /// A behind-window blur (``WindowMaterial/frosted``).
    case frosted
    /// Liquid Glass, regular style (Ghostty's `macos-glass-regular`).
    case glass
    /// Liquid Glass, clear style (Ghostty's `macos-glass-clear`).
    case glassClear = "glass-clear"
    /// `"none"`: no blur. A translucent window is plainly see-through
    /// (``WindowMaterial/translucent``); at opacity 1 it is opaque.
    case unblurred = "none"
}
