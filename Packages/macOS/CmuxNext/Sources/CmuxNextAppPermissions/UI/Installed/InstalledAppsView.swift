import SwiftUI

/// Installed Apps: every installed app with Hide/Unhide, Disable/Enable and
/// Remove, and a way to the hidden ones. Two prototypes: cards (default)
/// and dense rows.
struct InstalledAppsView: View {
    var model: AppInstallsModel
    var style: AppInstalledStyle
    var showHidden: @MainActor () -> Void
    @Environment(\.permissionColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch style {
            case .cards:
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(model.installed) { listing in
                        InstalledAppCard(listing: listing, model: model)
                    }
                }
            case .rows:
                VStack(spacing: 0) {
                    ForEach(Array(model.installed.enumerated()), id: \.element.id) { index, listing in
                        if index > 0 { Rectangle().fill(colors.separator).frame(height: 0.5).padding(.leading, 36) }
                        InstalledAppRow(listing: listing, model: model)
                    }
                }
            }
            HStack {
                if let reject = model.lastReject {
                    Text(AppInstallStrings.reject(reject)).font(colors.caption).foregroundStyle(colors.warning)
                }
                Spacer()
                Button(model.hidden.isEmpty ? AppInstallStrings.showHidden : AppInstallStrings.showHiddenCount(model.hidden.count),
                       action: showHidden)
                    .buttonStyle(PermissionButtonStyle(kind: .secondary))
            }
        }
        .padding(18)
    }
}

/// Variant `cards`: icon, name, tier, state chips and the actions.
struct InstalledAppCard: View {
    var listing: AppPermissionsListing
    var model: AppInstallsModel
    @Environment(\.permissionColors) private var colors

    var body: some View {
        let state = model.states[listing.id] ?? .notInstalled(listing.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AppGlyph(symbol: listing.symbol, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(listing.name).font(colors.emphasized).foregroundStyle(colors.text).lineLimit(1)
                    InstallStateChips(listing: listing, state: state)
                }
                Spacer(minLength: 0)
            }
            .opacity(state.hidden || !state.enabled ? 0.55 : 1)
            InstalledAppActions(listing: listing, state: state, model: model)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(colors.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(colors.separator, lineWidth: 0.5))
    }
}

/// Variant `rows`: one dense line per app.
struct InstalledAppRow: View {
    var listing: AppPermissionsListing
    var model: AppInstallsModel
    @Environment(\.permissionColors) private var colors

    var body: some View {
        let state = model.states[listing.id] ?? .notInstalled(listing.id)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                AppGlyph(symbol: listing.symbol, size: 24)
                Text(listing.name).font(colors.body).foregroundStyle(colors.text).lineLimit(1)
                InstallStateChips(listing: listing, state: state)
                Spacer(minLength: 8)
                InstalledAppActions(listing: listing, state: state, model: model, compact: true)
            }
            .opacity(state.hidden || !state.enabled ? 0.6 : 1)
        }
        .padding(.vertical, 6)
    }
}
