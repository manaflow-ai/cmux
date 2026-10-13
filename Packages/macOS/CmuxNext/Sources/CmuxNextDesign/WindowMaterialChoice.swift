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

extension WindowMaterialChoice {
    /// The choice that keeps the material Ghostty's `background-blur` gives,
    /// so a window that leaves Ghostty's values looks the same.
    ///
    /// - Parameter ghosttyBlur: `background-blur` in Ghostty's C encoding
    ///   (0 off, > 0 radius, -1 `macos-glass-regular`, -2 `macos-glass-clear`).
    public nonisolated init(ghosttyBlur: Int) {
        switch ghosttyBlur {
        case -2: self = .glassClear
        case ..<0: self = .glass
        case 0: self = .unblurred
        default: self = .frosted
        }
    }
}
