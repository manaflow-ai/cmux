import SwiftUI

/// Tier and state chips: Built in / Verified / Unverified, Team, Hidden, Disabled.
struct InstallStateChips: View {
    var listing: AppPermissionsListing
    var state: AppInstallState
    @Environment(\.permissionColors) private var colors

    var body: some View {
        HStack(spacing: 4) {
            TierBadge(tier: listing.tier)
            if state.source == .team { chip(AppInstallStrings.teamChip, color: colors.secondary) }
            if state.hidden { chip(AppInstallStrings.hiddenChip, color: colors.secondary) }
            if !state.enabled { chip(AppInstallStrings.disabledChip, color: colors.warning) }
        }
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text).font(colors.caption).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(colors.field))
    }
}

/// Hide/Unhide, Disable/Enable and Remove. A default-installed app's
/// Remove asks first and offers Hide Instead; a team app's Remove is
/// an admin's (members see it disabled).
struct InstalledAppActions: View {
    var listing: AppPermissionsListing
    var state: AppInstallState
    var model: AppInstallsModel
    var compact = false
    @Environment(\.permissionColors) private var colors

    var body: some View {
        if model.confirmingRemoval == listing.id {
            confirmation
        } else {
            HStack(spacing: compact ? 2 : 6) {
                Button(state.hidden ? AppInstallStrings.unhide : AppInstallStrings.hide) {
                    send(state.hidden ? .unhide : .hide)
                }
                .buttonStyle(PermissionButtonStyle(kind: compact ? .quiet : .secondary))
                Button(state.enabled ? AppInstallStrings.disable : AppInstallStrings.enable) {
                    send(state.enabled ? .disable : .enable)
                }
                .buttonStyle(PermissionButtonStyle(kind: compact ? .quiet : .secondary))
                if !compact { Spacer(minLength: 0) }
                let removable = model.canRemove(listing.id)
                Button(state.source == .default ? AppInstallStrings.removeEllipsis : AppInstallStrings.remove) {
                    Task { await model.remove(listing.id) }
                }
                .buttonStyle(PermissionButtonStyle(kind: .danger))
                .disabled(!removable)
                .opacity(removable ? 1 : 0.4)
                .help(removable ? "" : AppInstallStrings.adminOnly)
            }
            .font(colors.caption)
            .disabled(model.sending.contains(listing.id))
        }
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppInstallStrings.removeConfirm).font(colors.caption).foregroundStyle(colors.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button(AppInstallStrings.hideInstead) { send(.hide) }
                    .buttonStyle(PermissionButtonStyle(kind: .secondary))
                Spacer(minLength: 0)
                Button(AppInstallStrings.removeCompletely) { Task { await model.remove(listing.id) } }
                    .buttonStyle(PermissionButtonStyle(kind: .danger))
            }
        }
    }

    private func send(_ kind: AppStateOp.Kind) {
        Task { await model.send(kind, app: listing.id) }
    }
}

/// Show Hidden Apps: the only list that shows hidden apps, with Unhide and
/// the channels that still run each one.
struct HiddenAppsSheetView: View {
    var model: AppInstallsModel
    var done: @MainActor () -> Void
    @Environment(\.permissionColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppInstallStrings.hiddenTitle).font(colors.title).foregroundStyle(colors.text)
            Text(AppInstallStrings.hiddenDetail).font(colors.caption).foregroundStyle(colors.tertiary)
            if model.hidden.isEmpty {
                Text(AppInstallStrings.hiddenNone).font(colors.body).foregroundStyle(colors.secondary).padding(.vertical, 8)
            }
            ForEach(model.hidden) { listing in
                let access = model.states[listing.id]?.hiddenAccess ?? .all
                HStack(spacing: 10) {
                    AppGlyph(symbol: listing.symbol, size: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(listing.name).font(colors.body).foregroundStyle(colors.text)
                        AccessSummary(access: access)
                    }
                    Spacer()
                    Button(AppInstallStrings.unhide) { Task { await model.send(.unhide, app: listing.id) } }
                        .buttonStyle(PermissionButtonStyle(kind: .secondary))
                }
                .padding(.vertical, 4)
            }
            HStack {
                Spacer()
                Button(AppInstallStrings.done, action: done)
                    .buttonStyle(PermissionButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(18)
    }
}
