import SwiftUI

extension View {
    /// Gives the popover presentation the same appearance that browser chrome
    /// uses for its semantic foreground colors and terminal-derived backdrop.
    ///
    /// Browser chrome can intentionally differ from the app/window appearance.
    /// An environment-only override colors SwiftUI content but does not define
    /// the enclosing AppKit popover material. A presentation preference does
    /// both, so the material and every semantic foreground resolve together.
    func browserChromePopoverAppearance(_ colorScheme: ColorScheme) -> some View {
        preferredColorScheme(colorScheme)
    }
}
