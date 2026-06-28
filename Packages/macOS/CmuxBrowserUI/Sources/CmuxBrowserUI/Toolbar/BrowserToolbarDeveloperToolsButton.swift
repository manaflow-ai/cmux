public import SwiftUI

/// The developer-tools toolbar button: opens the web inspector. The glyph and
/// tint are configurable debug settings, resolved app-side into the snapshot.
public struct BrowserToolbarDeveloperToolsButton: View {
    private let snapshot: BrowserToolbarSnapshot
    private let actions: BrowserToolbarActions

    /// Creates the developer-tools button from a snapshot and action bundle.
    public init(snapshot: BrowserToolbarSnapshot, actions: BrowserToolbarActions) {
        self.snapshot = snapshot
        self.actions = actions
    }

    public var body: some View {
        Button(action: actions.onDevTools) {
            Image(systemName: snapshot.devToolsIconName)
                .symbolRenderingMode(.monochrome)
                .cmuxFlatSymbolColorRendering()
                .cmuxSymbolRasterSize(snapshot.accessoryIconFontSize, weight: .medium)
                .foregroundStyle(snapshot.devToolsTint)
                .frame(width: snapshot.buttonSize, height: snapshot.buttonSize, alignment: .center)
        }
        .buttonStyle(OmnibarAddressButtonStyle())
        .frame(width: snapshot.buttonSize, height: snapshot.buttonSize, alignment: .center)
        .safeHelp(snapshot.devToolsHelp)
        .accessibilityIdentifier("BrowserToggleDevToolsButton")
    }
}
