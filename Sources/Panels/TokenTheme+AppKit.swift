import AppKit
import CmuxSyntaxHighlighting

extension TokenTheme {
    /// Resolves light/dark token palettes from the view's effective appearance.
    init(appearance: NSAppearance?) {
        let resolved = appearance?.bestMatch(from: [.darkAqua, .aqua]) ?? NSAppearance.Name.aqua
        self = resolved == .darkAqua ? .dark : .light
    }
}
