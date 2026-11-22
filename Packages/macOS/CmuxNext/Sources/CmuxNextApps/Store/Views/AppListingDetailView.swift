import CmuxNextDesign
import CmuxNextIcons
import SwiftUI

/// A listing's page: icon, name, publisher and actions on one row, then the
/// description and only the sections that have something to say (a live
/// preview of each sidebar section and status item, permissions with their
/// reasons), then versions. Everything sits in the store column
/// (``AppStoreColumn``), so the header's actions end where the body does.
struct AppListingDetailView: View {
    let model: AppStoreModel
    let listing: AppStoreListing
    var showsBack = false
    @Environment(\.appSceneColors) private var colors

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.space6) {
                if showsBack { crumb }
                header
                Text(listing.description.resolved()).font(Font(Typography.body)).foregroundStyle(colors.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if !contributions.isEmpty { previews }
                if listing.requestsScopes { permissions }
                versions
            }
            .appStoreColumn()
            .padding(.vertical, Metrics.space5)
        }
        .accessibilityIdentifier("appStore.detail.\(listing.id)")
    }

    /// The crumb is the page's Back (the same step as the titlebar arrow and
    /// Cmd-[): it returns to where the listing was opened from.
    private var crumb: some View {
        Button {
            if !model.goBack() { model.show(.discover) }
        } label: {
            HStack(spacing: Metrics.space1) {
                Icon(.navBack, size: CGFloat.iconFloor)
                Text(model.backList.last?.tab == .installed ? AppsStrings.installed : AppsStrings.discover)
            }
            .font(Font(Typography.body))
            .foregroundStyle(colors.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("appStore.detail.back")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Metrics.space4) {
            AppIconView(icon: listing.icon, bundleDirectory: listing.bundle?.directory, size: 56)
            VStack(alignment: .leading, spacing: Metrics.space1) {
                Text(listing.name.resolved()).font(.system(size: 20, weight: .semibold)).foregroundStyle(colors.primary)
                    .lineLimit(1)
                meta
            }
            .layoutPriority(1)
            Spacer(minLength: Metrics.space4)
            HStack(spacing: Metrics.space4) {
                if let repository = listing.repository {
                    Link(destination: repository) {
                        HStack(spacing: Metrics.space1) {
                            Icon(.linkExternal, size: CGFloat.iconFloor)
                            Text(AppsStrings.openRepository)
                        }
                    }
                    .font(Font(Typography.body)).foregroundStyle(colors.secondary)
                }
                AppInstallButton(model: model, id: listing.id, builtIn: listing.isBuiltIn)
            }
        }
    }

    /// "by cmux (verified) · First party · Installed" as one quiet line of
    /// text: no tags.
    private var meta: some View {
        HStack(spacing: Metrics.space1) {
            Text(AppsStrings.publisher(listing.publisherName))
            if listing.publisherVerified { Icon(.trustVerified, size: CGFloat.iconFloor) }
            ForEach(metaParts, id: \.self) { part in
                Text(verbatim: "·").foregroundStyle(colors.tertiary)
                Text(part)
            }
        }
        .font(Font(Typography.caption))
        .foregroundStyle(colors.secondary)
        .lineLimit(1)
    }

    private var metaParts: [String] {
        var parts = [AppsStrings.tier(listing.tier)]
        if let state = model.state(of: listing.id), state.isInstalled {
            parts.append(state.isEnabled ? AppsStrings.installedBadge : AppsStrings.disabledBadge)
        }
        return parts
    }

    private var contributions: [AppContribution] {
        (listing.bundle?.manifest.contributes.entries ?? []).filter { $0.kind == .sidebarSection || $0.kind == .statusItem }
    }

    private var previews: some View {
        AppDetailSection(title: AppsStrings.preview, note: nil) {
            ForEach(contributions, id: \.id) { contribution in
                VStack(alignment: .leading, spacing: Metrics.space2) {
                    Text(AppsStrings.contribution(contribution.kind)).font(Font(Typography.caption)).foregroundStyle(colors.tertiary)
                    AppLivePreview(model: model, listing: listing, contribution: contribution)
                }
            }
        }
    }

    private var permissions: some View {
        AppDetailSection(title: AppsStrings.permissions, note: nil) {
            if let app = model.state(of: listing.id), app.isInstalled {
                AppGrantsView(model: model, app: app)
            } else {
                ForEach(listing.scopes) { AppScopeRow(scope: $0, optional: false) }
                ForEach(listing.optionalScopes) { AppScopeRow(scope: $0, optional: true) }
            }
        }
    }

    private var versions: some View {
        AppDetailSection(title: AppsStrings.versions, note: nil) {
            ForEach(listing.versions) { version in
                HStack(alignment: .firstTextBaseline, spacing: Metrics.space3) {
                    Text(version.version).font(Font(Typography.body).monospacedDigit()).foregroundStyle(colors.primary)
                    Text(AppsStrings.requires(version.engines)).font(Font(Typography.caption)).foregroundStyle(colors.secondary)
                    Spacer()
                }
            }
        }
    }
}

/// A titled block of the detail page.
struct AppDetailSection<Content: View>: View {
    let title: String
    let note: String?
    let content: Content
    @Environment(\.appSceneColors) private var colors

    init(title: String, note: String?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.note = note
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space3) {
            HStack(spacing: Metrics.space2) {
                Text(title).font(Font(Typography.header)).foregroundStyle(colors.secondary)
                if let note { Text(note).font(Font(Typography.caption)).foregroundStyle(colors.tertiary) }
            }
            content
        }
    }
}

/// One requested scope and its reason.
struct AppScopeRow: View {
    let scope: AppScopeRequest
    let optional: Bool
    @Environment(\.appSceneColors) private var colors

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.space3) {
            Icon(optional ? .appPermissions : .actionConfirm, size: CGFloat.iconFloor).foregroundStyle(colors.secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Metrics.space2) {
                    Text(scope.scope).font(Font(Typography.shortcut)).foregroundStyle(colors.primary)
                    if optional { AppStoreBadge(text: AppsStrings.optionalPermissions) }
                }
                Text(scope.reason).font(Font(Typography.caption)).foregroundStyle(colors.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
