import SwiftUI

extension View {
    /// Reports this trailing toolbar item's rendered content width into the
    /// shared measurement dictionary.
    ///
    /// The leading title menu caps its width to the bar's remaining space so
    /// the trailing items are never squeezed into the overflow More menu.
    /// Deliberately no `onDisappear` cleanup: overflowing into More also
    /// removes the bar content, so clearing on disappear would release the
    /// reservation and make the collapse sticky. Callers that structurally
    /// remove an item clear its key from the condition that removed it.
    func measureTrailingToolbarItem(
        _ key: String,
        into widths: Binding<[String: CGFloat]>
    ) -> some View {
        onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            widths.wrappedValue[key] = width
        }
    }
}
