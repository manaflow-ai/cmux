import CmuxNextDesign
import SwiftUI

/// A listing as an item card (grid layout): icon, name, publisher, description, its states and
/// Install or Remove; the body opens its page.
struct AppListingCard: View {
    let model: AppStoreModel
    let listing: AppStoreListing

    var body: some View {
        AppStoreItemCard(look: model.cardLook, artwork: .app(listing.icon, listing.bundleDirectory), name: listing.name.resolved(),
                         byline: AppsStrings.publisher(listing.publisherName), summary: listing.description.resolved(),
                         states: listing.installStates(model.state(of: listing.id)) + [AppStoreItemState(text: AppsStrings.tier(listing.tier))],
                         open: { model.show(.discover, selection: listing.id) },
                         secondary: { EmptyView() },
                         primary: { AppInstallButton(model: model, id: listing.id, builtIn: listing.isBuiltIn) })
            .accessibilityIdentifier("appStore.listing.\(listing.id)")
    }
}

extension AppStoreListing {
    /// Installed (or Disabled) and Hidden, while the app is installed.
    func installStates(_ state: AppRecord?) -> [AppStoreItemState] {
        guard let state, state.installed else { return [] }
        var states = [AppStoreItemState(text: state.enabled ? AppsStrings.installedBadge : AppsStrings.disabledBadge, emphasized: state.enabled)]
        if state.hidden { states.append(AppStoreItemState(text: AppsStrings.hiddenBadge)) }
        return states
    }
}

/// A listing as a dense row (list and split layouts).
struct AppListingRow: View {
    let model: AppStoreModel
    let listing: AppStoreListing
    var selected = false
    var showsInstall = true
    @State private var hovered = false
    @Environment(\.appSceneColors) private var colors

    var body: some View {
        HStack(spacing: Metrics.space3) {
            AppIconView(icon: listing.icon, bundleDirectory: listing.bundleDirectory, size: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text(listing.name.resolved()).font(Font(Typography.bodyEmphasized)).foregroundStyle(colors.primary).lineLimit(1)
                Text(listing.description.resolved()).font(Font(Typography.caption)).foregroundStyle(colors.secondary).lineLimit(1)
            }
            Spacer(minLength: Metrics.space2)
            AppListingBadges(model: model, listing: listing)
            if showsInstall { AppInstallButton(model: model, id: listing.id) }
        }
        .padding(.horizontal, Metrics.space3)
        .frame(minHeight: Metrics.sidebarRowHeightWithSubtitle + Metrics.space2)
        .background(RoundedRectangle(cornerRadius: Metrics.itemCornerRadius, style: .continuous)
            .fill(selected ? colors.selection : hovered ? colors.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { model.show(.discover, selection: listing.id) }
    }
}

/// Install state and tier badges.
struct AppListingBadges: View {
    let model: AppStoreModel
    let listing: AppStoreListing

    var body: some View {
        HStack(spacing: Metrics.space1) {
            ForEach(listing.installStates(model.state(of: listing.id)), id: \.self) { AppStoreBadge(text: $0.text, emphasized: $0.emphasized) }
            AppStoreBadge(text: AppsStrings.tier(listing.tier))
        }
    }
}
