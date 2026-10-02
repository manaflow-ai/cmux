import CmuxNextDesign
import SwiftUI

/// A listing as a card (grid layout).
struct AppListingCard: View {
    let model: AppStoreModel
    let listing: AppStoreListing
    @State private var hovered = false
    @Environment(\.appSceneColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space3) {
            HStack(alignment: .top) {
                AppIconView(icon: listing.icon, bundleDirectory: listing.bundle?.directory, size: 44)
                Spacer()
                AppListingBadges(model: model, listing: listing)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(listing.name.resolved()).font(Font(Typography.bodyEmphasized)).foregroundStyle(colors.primary)
                Text(AppsStrings.publisher(listing.publisherName)).font(Font(Typography.caption)).foregroundStyle(colors.tertiary)
            }
            Text(listing.description.resolved())
                .font(Font(Typography.caption)).foregroundStyle(colors.secondary).lineLimit(3)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
        }
        .padding(Metrics.space4)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hovered ? colors.selection : colors.hover))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { model.selection = listing.id }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
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
            AppIconView(icon: listing.icon, bundleDirectory: listing.bundle?.directory, size: 28)
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
        .onTapGesture { model.selection = listing.id }
    }
}

/// Tier and install state badges.
struct AppListingBadges: View {
    let model: AppStoreModel
    let listing: AppStoreListing

    var body: some View {
        HStack(spacing: Metrics.space1) {
            if let state = model.state(of: listing.id), state.isInstalled {
                AppStoreBadge(text: state.isEnabled ? AppsStrings.installedBadge : AppsStrings.disabledBadge, emphasized: state.isEnabled)
            }
            AppStoreBadge(text: AppsStrings.tier(listing.tier))
        }
    }
}
