public import SwiftUI

/// The browser-profile toolbar button label. Tapping it runs the toggle action;
/// the app-side forwarder anchors the profile popover, help, and accessibility
/// identifier around this button so the `@State` presentation flag and popover
/// content stay app-side.
public struct BrowserToolbarProfileButton: View {
    private let snapshot: BrowserToolbarSnapshot
    private let actions: BrowserToolbarActions

    /// Creates the profile button label from a snapshot and action bundle.
    public init(snapshot: BrowserToolbarSnapshot, actions: BrowserToolbarActions) {
        self.snapshot = snapshot
        self.actions = actions
    }

    public var body: some View {
        Button(action: actions.onProfileToggle) {
            Image(systemName: "person.crop.circle")
                .symbolRenderingMode(.monochrome)
                .cmuxFlatSymbolColorRendering()
                .cmuxSymbolRasterSize(snapshot.accessoryIconFontSize, weight: .medium)
                .foregroundStyle(snapshot.devToolsTint)
                .frame(width: snapshot.buttonSize, height: snapshot.buttonSize, alignment: .center)
        }
        .buttonStyle(OmnibarAddressButtonStyle())
        .frame(width: snapshot.buttonSize, height: snapshot.buttonSize, alignment: .center)
    }
}
