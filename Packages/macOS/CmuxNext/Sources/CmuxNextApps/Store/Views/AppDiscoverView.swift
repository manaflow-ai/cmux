import CmuxNextDesign
import SwiftUI

/// Discover: category chips, then listings in the `apps.store.layout`
/// prototype (grid, list, split), then cmux's own features by category. In grid and list a
/// selection replaces the page with the detail page; split shows both and lists apps only.
struct AppDiscoverView: View {
    let model: AppStoreModel
    @Environment(\.appSceneColors) private var colors

    var body: some View {
        switch model.layout {
        case .split:
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    chips
                    ScrollView { LazyVStack(spacing: 2) { rows(showsInstall: false) }.padding(Metrics.space3).thinScrollers() }
                }
                .frame(width: 320)
                Rectangle().fill(colors.separator).frame(width: Borders.width(1))
                if let listing = model.selectedListing ?? model.listings.first {
                    AppListingDetailView(model: model, listing: listing).id(listing.id)
                } else {
                    empty(AppsStrings.selectApp)
                }
            }
        case .grid, .list:
            if let listing = model.selectedListing {
                AppListingDetailView(model: model, listing: listing, showsBack: true).id(listing.id)
            } else {
                VStack(spacing: 0) {
                    chips
                    ScrollView {
                        VStack(alignment: .leading, spacing: Metrics.space5) {
                            if let open = model.onOpenApp, model.query.isEmpty, model.category == nil, model.discoverShowsListings {
                                AppCloudFeature(open: open)
                            }
                            if model.discoverShowsListings {
                                if model.layout == .grid {
                                    AppStoreCardGrid(look: model.cardLook) { ForEach(model.listings) { AppListingCard(model: model, listing: $0) } }
                                } else {
                                    LazyVStack(spacing: 2) { rows(showsInstall: true) }
                                }
                            }
                            ForEach(model.discoverFeatureSections) { section in
                                VStack(alignment: .leading, spacing: Metrics.space3) {
                                    Text(AppsStrings.featureCategory(section.category))
                                        .font(Font(Typography.header)).foregroundStyle(colors.primary)
                                        .accessibilityAddTraits(.isHeader)
                                    AppStoreCardGrid(look: model.cardLook) { ForEach(section.features) { AppFeatureCard(model: model, feature: $0) } }
                                }
                                .accessibilityIdentifier("appStore.discover.features.\(section.category.rawValue)")
                            }
                        }
                        .appStoreWideColumn()
                        .padding(.vertical, Metrics.space4)
                        .thinScrollers()
                    }
                    .overlay {
                        if (!model.discoverShowsListings || model.listings.isEmpty) && model.discoverFeatureSections.isEmpty {
                            empty(model.client.unavailableReason.map(AppsStrings.unavailable) ?? AppsStrings.noMatches)
                        }
                    }
                }
            }
        }
    }

    private func rows(showsInstall: Bool) -> some View {
        ForEach(model.listings) { listing in
            AppListingRow(model: model, listing: listing, selected: model.layout == .split && listing.id == (model.selection ?? model.listings.first?.id),
                          showsInstall: showsInstall)
        }
    }

    private var chips: some View {
        AppStoreCategoryBar(chips: chipItems)
            // On the scroll view: inside it the column gets an unbounded width and stays at the edge.
            .modifier(AppStoreColumnModifier(enabled: model.layout != .split, fallbackPadding: Metrics.space5, maxWidth: AppStoreColumn.wideMaxWidth))
    }

    /// All, the apps' categories, then (not in split, which lists apps only) the feature sections'
    /// categories: one shows only that section.
    private var chipItems: [AppStoreCategoryBar.Chip] {
        var chips = [AppStoreCategoryBar.Chip(id: "all", title: AppsStrings.allCategories, selected: model.category == nil && model.featureCategory == nil) {
            model.category = nil
            model.featureCategory = nil
        }]
        chips += model.allCategories.map { id in
            AppStoreCategoryBar.Chip(id: "app.\(id)", title: AppsStrings.category(id), selected: model.category == id) {
                model.featureCategory = nil
                model.category = model.category == id ? nil : id
            }
        }
        if model.layout != .split {
            chips += model.featureCategories.map { category in
                AppStoreCategoryBar.Chip(id: category.rawValue, title: AppsStrings.featureCategory(category), selected: model.featureCategory == category) {
                    model.category = nil
                    model.featureCategory = model.featureCategory == category ? nil : category
                }
            }
        }
        return chips
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(Font(Typography.body)).foregroundStyle(colors.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
