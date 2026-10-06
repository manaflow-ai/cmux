import CmuxNextDesign
import SwiftUI

/// Discover: category chips, then listings in the `apps.store.layout`
/// prototype (grid, list, split). In grid and list a selection replaces the
/// listings with the detail page; split shows both.
struct AppDiscoverView: View {
    let model: AppStoreModel
    @Environment(\.appSceneColors) private var colors

    var body: some View {
        switch model.layout {
        case .split:
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    chips
                    ScrollView { LazyVStack(spacing: 2) { rows(showsInstall: false) }.padding(Metrics.space3) }
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
                        if model.layout == .grid {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: Metrics.space4)], spacing: Metrics.space4) {
                                ForEach(model.listings) { AppListingCard(model: model, listing: $0) }
                            }
                            .padding(Metrics.space5)
                        } else {
                            LazyVStack(spacing: 2) { rows(showsInstall: true) }.padding(Metrics.space4)
                        }
                    }
                    .overlay { if model.listings.isEmpty { empty(model.loadError.map { _ in AppsStrings.loadFailed } ?? AppsStrings.noMatches) } }
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
        ScrollView(.horizontal) {
            HStack(spacing: Metrics.space2) {
                chip(AppsStrings.allCategories, selected: model.category == nil) { model.category = nil }
                ForEach(model.allCategories, id: \.self) { id in
                    chip(AppsStrings.category(id), selected: model.category == id) { model.category = model.category == id ? nil : id }
                }
            }
            .padding(.horizontal, Metrics.space5)
            .padding(.vertical, Metrics.space3)
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Font(Typography.caption))
                .foregroundStyle(selected ? colors.primary : colors.secondary)
                .padding(.horizontal, Metrics.space3)
                .padding(.vertical, Metrics.space1)
                .background(Capsule().fill(selected ? colors.selection : colors.hover))
        }
        .buttonStyle(.plain)
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(Font(Typography.body)).foregroundStyle(colors.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
