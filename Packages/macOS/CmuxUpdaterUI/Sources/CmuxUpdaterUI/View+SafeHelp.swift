import SwiftUI

extension View {
    /// Applies a help tooltip, skipping it when `text` is empty so an empty tooltip never shows.
    @ViewBuilder
    func safeHelp(_ text: String) -> some View {
        if text.isEmpty {
            self
        } else {
            self.help(text)
        }
    }
}
