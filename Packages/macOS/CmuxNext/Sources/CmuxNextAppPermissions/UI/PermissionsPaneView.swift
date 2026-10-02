import SwiftUI

/// Settings > Apps > <app> > Permissions (section 5.4): scopes with
/// toggles and approval modes, profile, reach, folders, activity, Revoke
/// all, Remove app data.
struct PermissionsPaneView: View {
    var model: AppPermissionsModel
    var style: AppPermissionsStyle
    @Environment(\.permissionColors) private var colors

    var body: some View {
        if let listing = model.selected, let record = model.records[listing.id] {
            content(listing, record)
        }
    }

    private func content(_ listing: AppPermissionsListing, _ record: AppPermissionRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            AppHeader(listing: listing)
            if record.grant.disabled {
                HStack {
                    Text(AppPermissionsStrings.disabled).font(colors.caption).foregroundStyle(colors.secondary)
                    Spacer()
                    Button(AppPermissionsStrings.enable) { send(.enable, listing) }
                        .buttonStyle(PermissionButtonStyle(kind: .secondary))
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(colors.field))
            }
            PermissionsPresentation(style: style, tier: record.tier, profile: record.profile,
                                    rows: ScopeRows.settings(record, listing: listing), actions: actions(listing)) {
                send(.setProfile($0), listing)
            }
            if declaresFiles(listing) {
                FoldersSection(record: record, add: { Task { await model.addFolder(appID: listing.id) } },
                               remove: { send(.removeFileRoot(id: $0), listing) })
            }
            ReachSection(selectors: record.grant.selectors, source: model.source) { send(.setSelectors($0), listing) }
            ActivitySection(entries: model.activity[listing.id] ?? [])
            Rectangle().fill(colors.separator).frame(height: 0.5).padding(.top, 4)
            HStack {
                Button(AppPermissionsStrings.revokeAll) { send(.revokeAll, listing) }
                    .buttonStyle(PermissionButtonStyle(kind: .danger))
                    .disabled(record.grant.disabled)
                Spacer()
                Button(AppPermissionsStrings.removeData) { Task { await model.removeAppData(appID: listing.id) } }
                    .buttonStyle(PermissionButtonStyle(kind: .quiet))
            }
        }
        .padding(18)
    }

    private func declaresFiles(_ listing: AppPermissionsListing) -> Bool {
        (listing.required + listing.optional).contains { AppScopeKind($0.scope).isFiles }
    }

    private func send(_ change: AppGrantChange, _ listing: AppPermissionsListing) {
        Task { await model.apply(change, appID: listing.id) }
    }

    private func actions(_ listing: AppPermissionsListing) -> ScopeRowActions {
        ScopeRowActions(
            setOn: { scope, on in
                let rows = model.records[listing.id].map { ScopeRows.settings($0, listing: listing) } ?? []
                let approval = rows.first { $0.scope == scope }?.approval ?? .always
                send(.setApproval(scope: scope, approval: on ? approval : .denied), listing)
            },
            setApproval: { scope, approval in send(.setApproval(scope: scope, approval: approval), listing) })
    }
}
