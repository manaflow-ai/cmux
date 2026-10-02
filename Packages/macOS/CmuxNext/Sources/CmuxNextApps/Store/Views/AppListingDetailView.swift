import CmuxNextDesign
import SwiftUI

/// A listing's page: icon, description, tier, Install/Remove, a live
/// preview of each sidebar section and status item, permissions with their
/// reasons, versions, repository.
struct AppListingDetailView: View {
    let model: AppStoreModel
    let listing: AppStoreListing
    var showsBack = false
    @Environment(\.appSceneColors) private var colors

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.space6) {
                if showsBack {
                    Button { model.selection = nil } label: {
                        Label(AppsStrings.discover, systemImage: "chevron.backward").font(Font(Typography.body))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(colors.secondary)
                }
                header
                Text(listing.description.resolved()).font(Font(Typography.body)).foregroundStyle(colors.primary)
                    .fixedSize(horizontal: false, vertical: true)
                previews
                permissions
                versions
                AppPrototypeNote()
            }
            .padding(Metrics.space6)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .accessibilityIdentifier("appStore.detail.\(listing.id)")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Metrics.space4) {
            AppIconView(icon: listing.icon, bundleDirectory: listing.bundle?.directory, size: 64)
            VStack(alignment: .leading, spacing: Metrics.space1) {
                Text(listing.name.resolved()).font(.system(size: 20, weight: .semibold)).foregroundStyle(colors.primary)
                HStack(spacing: Metrics.space2) {
                    Text(AppsStrings.publisher(listing.publisherName)).font(Font(Typography.caption)).foregroundStyle(colors.secondary)
                    if listing.publisherVerified {
                        Image(systemName: "checkmark.seal").font(.system(size: 10)).foregroundStyle(colors.secondary)
                    }
                    AppListingBadges(model: model, listing: listing)
                }
            }
            Spacer()
            if let repository = listing.repository {
                Link(destination: repository) { Label(AppsStrings.openRepository, systemImage: "arrow.up.right.square") }
                    .font(Font(Typography.caption)).foregroundStyle(colors.secondary)
            }
            AppInstallButton(model: model, id: listing.id)
        }
    }

    @ViewBuilder
    private var previews: some View {
        let contributions = (listing.bundle?.manifest.contributes.entries ?? []).filter { $0.kind == .sidebarSection || $0.kind == .statusItem }
        AppDetailSection(title: AppsStrings.preview,
                         note: model.state(of: listing.id)?.isActive == true ? nil : AppsStrings.previewSample) {
            if contributions.isEmpty {
                Text(AppsStrings.noPreview).font(Font(Typography.caption)).foregroundStyle(colors.tertiary)
            }
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
            if listing.scopes.isEmpty, listing.optionalScopes.isEmpty {
                Text(AppsStrings.noPermissions).font(Font(Typography.caption)).foregroundStyle(colors.tertiary)
            }
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
                HStack(spacing: Metrics.space3) {
                    Text(version.version).font(Font(Typography.bodyEmphasized).monospacedDigit()).foregroundStyle(colors.primary)
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
            Image(systemName: optional ? "circle.dashed" : "checkmark.circle").font(.system(size: 11)).foregroundStyle(colors.secondary)
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
