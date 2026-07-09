public import SwiftUI

/// The React Grab toolbar button: injects/toggles the React element grabber and
/// tints with the accent color while a grab session is active.
public struct BrowserToolbarReactGrabButton: View {
    private let snapshot: BrowserToolbarSnapshot
    private let actions: BrowserToolbarActions

    /// Creates the React Grab button from a snapshot and action bundle.
    public init(snapshot: BrowserToolbarSnapshot, actions: BrowserToolbarActions) {
        self.snapshot = snapshot
        self.actions = actions
    }

    public var body: some View {
        Button(action: actions.onReactGrab) {
            Image(systemName: "cursorarrow.click.2")
                .symbolRenderingMode(.monochrome)
                .cmuxFlatSymbolColorRendering()
                .cmuxSymbolRasterSize(snapshot.accessoryIconFontSize, weight: .medium)
                .foregroundStyle(snapshot.isReactGrabActive ? Color.accentColor : Color.secondary)
                .frame(width: snapshot.buttonSize, height: snapshot.buttonSize, alignment: .center)
        }
        .buttonStyle(OmnibarAddressButtonStyle())
        .frame(width: snapshot.buttonSize, height: snapshot.buttonSize, alignment: .center)
        .safeHelp(snapshot.reactGrabHelp)
        .accessibilityIdentifier("BrowserReactGrabButton")
    }
}
