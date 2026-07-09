public import SwiftUI

/// The browser-profile popover content: a checkmarked list of profiles followed
/// by the new-profile, import-browser-data, and (conditionally) rename rows.
///
/// Renders from a ``BrowserProfilePopoverSnapshot`` and routes every tap through
/// ``BrowserProfilePopoverActions``; the panel mutations and `@State` popover
/// dismissals live on the app-side forwarder that builds those values, which
/// also hosts the `.popover(isPresented:)` modifier around the profile button.
public struct BrowserProfilePopoverView: View {
    private let snapshot: BrowserProfilePopoverSnapshot
    private let actions: BrowserProfilePopoverActions

    /// Creates the profile popover content from a snapshot and action bundle.
    public init(snapshot: BrowserProfilePopoverSnapshot, actions: BrowserProfilePopoverActions) {
        self.snapshot = snapshot
        self.actions = actions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(snapshot.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(snapshot.profiles) { profile in
                    Button {
                        actions.onSelectProfile(profile.id)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: profile.isSelected ? "checkmark" : "circle")
                                .cmuxSymbolRasterSize(10, weight: .semibold)
                                .opacity(profile.isSelected ? 1.0 : 0.0)
                                .frame(width: 12, alignment: .center)
                            Text(profile.displayName)
                                .font(.system(size: 12))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(profile.isSelected ? Color.primary.opacity(0.12) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            Button {
                actions.onCreateProfile()
            } label: {
                Text(snapshot.newProfileLabel)
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)

            Button {
                actions.onOpenImportSettings()
            } label: {
                Text(snapshot.importLabel)
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)

            if snapshot.canRenameActiveProfile {
                Button {
                    actions.onRenameProfile()
                } label: {
                    Text(snapshot.renameLabel)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, snapshot.horizontalPadding)
        .padding(.vertical, snapshot.verticalPadding)
        .frame(minWidth: 208)
    }
}
