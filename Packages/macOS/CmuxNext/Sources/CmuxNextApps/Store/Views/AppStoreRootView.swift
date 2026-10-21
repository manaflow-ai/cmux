public import CmuxNextDesign
import CmuxNextIcons
public import SwiftUI

/// The App Store window's content: a toolbar row (Discover / Features / Installed,
/// search, prototype label), the disconnected banner while the supervisor
/// is unreachable, and the selected tab.
public struct AppStoreRootView: View {
    let model: AppStoreModel
    /// Hosted in a pane (internal page tab): no traffic-light inset and a
    /// toolbar of the titlebar's height.
    let inPane: Bool
    @Environment(\.appSceneColors) private var colors

    public init(model: AppStoreModel, inPane: Bool = false) {
        self.model = model
        self.inPane = inPane
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(colors.separator).frame(height: Borders.width(1))
            if let reason = model.client.unavailableReason {
                AppsDisconnectedBanner(reason: reason, recovery: reason.daemonUnreachable ? model.recovery?() : nil)
            }
            switch model.tab {
            case .discover: AppDiscoverView(model: model)
            case .features: AppFeaturesView(model: model)
            case .installed: AppInstalledView(model: model)
            }
        }
        .background(colors.background)
        .onAppear { model.refresh() }
    }

    private var toolbar: some View {
        HStack(spacing: Metrics.space4) {
            HStack(spacing: 2) {
                tab(.discover, AppsStrings.discover)
                if model.features != nil { tab(.features, AppsStrings.features) }
                tab(.installed, AppsStrings.installed)
            }
            .padding(2)
            .background(Capsule().fill(colors.hover))
            Spacer()
            HStack(spacing: Metrics.space2) {
                Icon(.search, size: CGFloat.iconFloor).foregroundStyle(colors.tertiary)
                ThemedField(text: Binding(get: { model.query }, set: { model.query = $0 }), placeholder: model.tab == .features ? AppsStrings.searchFeatures : AppsStrings.search,
                            height: 18, boxed: false, identifier: "appStore.search")
                    .frame(width: 200)
            }
            .padding(.horizontal, Metrics.space3)
            .frame(height: 26)
            .background(Capsule().fill(colors.hover))
        }
        // The same column as the page below it (the wide grid on Discover and Features, the
        // reading column on a detail page and Installed); the split layout's list runs edge to
        // edge, so its toolbar does too.
        .modifier(AppStoreColumnModifier(enabled: model.layout != .split, fallbackPadding: Metrics.space4,
                                          maxWidth: model.tab == .installed || model.selectedListing != nil ? AppStoreColumn.maxWidth : AppStoreColumn.wideMaxWidth))
        // The window's toolbar row starts after the traffic lights; a pane has none.
        .padding(.leading, inPane ? 0 : 84)
        .frame(height: inPane ? Metrics.titlebarHeight : Metrics.titlebarHeight + Metrics.space2)
    }

    private func tab(_ tab: AppStoreModel.Tab, _ title: String) -> some View {
        Button {
            // A tab switch is a page navigation (Back returns to the listing it left).
            model.show(tab, selection: tab == .discover && model.layout == .split ? model.selection : nil)
        } label: {
            Text(title)
                .font(Font(Typography.bodyEmphasized))
                .foregroundStyle(model.tab == tab ? colors.primary : colors.secondary)
                .padding(.horizontal, Metrics.space3)
                .padding(.vertical, 3)
                .background(Capsule().fill(model.tab == tab ? colors.selection : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("appStore.tab.\(tab.rawValue)")
    }
}

/// The store's content column: centered, so the header, its actions and the body share one
/// grid at any window width. Reading pages (a detail page, Installed) stop at ``maxWidth``;
/// the card grids of Discover and Features use the page up to ``wideMaxWidth``.
enum AppStoreColumn {
    static let maxWidth: CGFloat = 760
    static let wideMaxWidth: CGFloat = 1600
    /// Tags and small labels: a small-radius rectangle, never a capsule.
    static let tagRadius: CGFloat = 4
    /// Install, Remove and Undo share one height.
    static let actionHeight: CGFloat = 26
}

/// Centers content in the store column; `enabled` false keeps the edge
/// padding only (the split layout).
struct AppStoreColumnModifier: ViewModifier {
    var enabled = true
    var fallbackPadding: CGFloat = Metrics.space6
    var maxWidth = AppStoreColumn.maxWidth

    func body(content: Content) -> some View {
        if enabled {
            content
                .frame(maxWidth: maxWidth, alignment: .leading)
                .padding(.horizontal, Metrics.space6)
                .frame(maxWidth: .infinity)
        } else {
            content.padding(.horizontal, fallbackPadding)
        }
    }
}

extension View {
    /// Centers the view in the store column (``AppStoreColumn``).
    func appStoreColumn() -> some View { modifier(AppStoreColumnModifier()) }
    /// Centers the view in the wide card column (``AppStoreColumn/wideMaxWidth``).
    func appStoreWideColumn() -> some View { modifier(AppStoreColumnModifier(maxWidth: AppStoreColumn.wideMaxWidth)) }
}
