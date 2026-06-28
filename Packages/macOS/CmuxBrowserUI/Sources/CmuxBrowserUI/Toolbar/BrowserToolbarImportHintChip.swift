public import SwiftUI

/// The browser-data import hint chip shown in the toolbar when an import is
/// available. Tapping it runs the toggle action; the app-side forwarder anchors
/// the import popover, help, and accessibility identifier so the `@State`
/// presentation flag and popover content stay app-side.
public struct BrowserToolbarImportHintChip: View {
    private let snapshot: BrowserToolbarSnapshot
    private let actions: BrowserToolbarActions

    /// Creates the import hint chip from a snapshot and action bundle.
    public init(snapshot: BrowserToolbarSnapshot, actions: BrowserToolbarActions) {
        self.snapshot = snapshot
        self.actions = actions
    }

    public var body: some View {
        Button(action: actions.onImportToggle) {
            HStack(spacing: 4) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .cmuxSymbolRasterSize(10, weight: .medium)
                Text(snapshot.importToolbarText)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(snapshot.devToolsTint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .buttonStyle(OmnibarAddressButtonStyle())
    }
}
