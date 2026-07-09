import SwiftUI

extension View {
    /// Attaches a `.help` tooltip only when `text` is non-empty, matching the
    /// app target's `safeHelp` backport. Kept module-internal to the browser UI
    /// so the lifted top-chrome views carry no app-target dependency.
    @ViewBuilder
    func safeHelp(_ text: String) -> some View {
        if text.isEmpty {
            self
        } else {
            self.help(text)
        }
    }
}
