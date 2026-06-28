public import SwiftUI

/// The browser-theme popover content: a checkmarked list of theme modes
/// (system / light / dark).
///
/// Renders from a ``BrowserThemePopoverSnapshot`` and routes every tap through
/// ``BrowserThemePopoverActions``; the panel mutation and `@State` popover
/// dismissal live on the app-side forwarder that builds those values, which also
/// hosts the `.popover(isPresented:)` modifier around the theme button.
public struct BrowserThemePopoverView: View {
    private let snapshot: BrowserThemePopoverSnapshot
    private let actions: BrowserThemePopoverActions

    /// Creates the theme popover content from a snapshot and action bundle.
    public init(snapshot: BrowserThemePopoverSnapshot, actions: BrowserThemePopoverActions) {
        self.snapshot = snapshot
        self.actions = actions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(snapshot.options) { option in
                Button {
                    actions.onSelectThemeMode(option.id)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: option.isSelected ? "checkmark" : "circle")
                            .cmuxSymbolRasterSize(10, weight: .semibold)
                            .opacity(option.isSelected ? 1.0 : 0.0)
                            .frame(width: 12, alignment: .center)
                        Text(option.displayName)
                            .font(.system(size: 12))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(option.isSelected ? Color.primary.opacity(0.12) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(option.accessibilityIdentifier)
            }
        }
        .padding(8)
        .frame(minWidth: 128)
    }
}
