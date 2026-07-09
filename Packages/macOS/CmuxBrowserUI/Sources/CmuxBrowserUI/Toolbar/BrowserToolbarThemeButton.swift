public import SwiftUI

/// The browser-theme toolbar button label (system/light/dark glyph). Tapping it
/// runs the toggle action; the app-side forwarder anchors the theme popover,
/// help, and accessibility identifier so the `@State` presentation flag and
/// popover content stay app-side.
public struct BrowserToolbarThemeButton: View {
    private let snapshot: BrowserToolbarSnapshot
    private let actions: BrowserToolbarActions

    /// Creates the theme button label from a snapshot and action bundle.
    public init(snapshot: BrowserToolbarSnapshot, actions: BrowserToolbarActions) {
        self.snapshot = snapshot
        self.actions = actions
    }

    public var body: some View {
        Button(action: actions.onThemeToggle) {
            Image(systemName: snapshot.themeIconName)
                .symbolRenderingMode(.monochrome)
                .cmuxFlatSymbolColorRendering()
                .cmuxSymbolRasterSize(snapshot.accessoryIconFontSize, weight: .medium)
                .foregroundStyle(snapshot.themeIconColor)
                .frame(width: snapshot.buttonSize, height: snapshot.buttonSize, alignment: .center)
        }
        .buttonStyle(OmnibarAddressButtonStyle())
        .frame(width: snapshot.buttonSize, height: snapshot.buttonSize, alignment: .center)
    }
}
