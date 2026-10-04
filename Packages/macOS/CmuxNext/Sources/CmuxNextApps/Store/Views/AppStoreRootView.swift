public import CmuxNextDesign
public import SwiftUI

/// The App Store window's content: a toolbar row (Discover / Installed,
/// search, prototype label) and the selected tab.
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
            switch model.tab {
            case .discover: AppDiscoverView(model: model)
            case .installed: AppInstalledView(model: model)
            }
        }
        .background(colors.background)
        .onAppear { if model.listings.isEmpty { model.refresh() } }
    }

    private var toolbar: some View {
        HStack(spacing: Metrics.space4) {
            HStack(spacing: 2) {
                tab(.discover, AppsStrings.discover)
                tab(.installed, AppsStrings.installed)
            }
            .padding(2)
            .background(Capsule().fill(colors.hover))
            Spacer()
            HStack(spacing: Metrics.space2) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(colors.tertiary)
                TextField(AppsStrings.search, text: Binding(get: { model.query }, set: { model.query = $0 }))
                    .textFieldStyle(.plain)
                    .font(Font(Typography.body))
                    .frame(width: 200)
                    .accessibilityIdentifier("appStore.search")
            }
            .padding(.horizontal, Metrics.space3)
            .frame(height: 26)
            .background(Capsule().fill(colors.hover))
        }
        // The window's toolbar row starts after the traffic lights; a pane has none.
        .padding(.leading, inPane ? Metrics.space4 : 84)
        .padding(.trailing, Metrics.space4)
        .frame(height: inPane ? Metrics.titlebarHeight : Metrics.titlebarHeight + Metrics.space2)
    }

    private func tab(_ tab: AppStoreModel.Tab, _ title: String) -> some View {
        Button {
            model.tab = tab
            if tab == .discover { model.selection = model.layout == .split ? model.selection : nil }
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
