public import SwiftUI

/// The red "THIS IS A DEV BUILD" banner shown beneath the sidebar footer
/// buttons on debug builds.
///
/// A pure presentation leaf: the banner text is resolved (and localized)
/// app-side and passed in, so the package view holds no app-target dependency
/// and binds to no bundle. The visibility gate (the debug `AppStorage` flag)
/// stays at the call site; this view only renders the styled label.
public struct SidebarDevBuildBanner: View {
    let text: String

    /// Creates the dev-build banner label.
    /// - Parameter text: The resolved (already localized) banner text.
    public init(text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.red)
    }
}
