import CmuxNextDesign
import SwiftUI

/// A live preview of one contribution: the app's real code renders through
/// AppSceneView. Installed, enabled apps run on the real host with their
/// grant; others on the preview host with sample data and no grant.
struct AppLivePreview: View {
    let model: AppStoreModel
    let listing: AppStoreListing
    let contribution: AppContribution
    @State private var mount: AppMount?
    @State private var host: AppHost?
    @Environment(\.appSceneColors) private var colors

    var body: some View {
        Group {
            if let mount {
                switch contribution.kind {
                case .statusItem:
                    AppStatusItemFrame { AppSceneView(model: mount.model, bundleDirectory: mount.bundleDirectory).fixedSize() }
                default:
                    AppSectionFrame(look: model.look, title: contribution.title?.resolved() ?? listing.name.resolved(),
                                    symbol: contribution.symbol, icon: listing.icon, bundleDirectory: listing.bundle?.directory) {
                        AppSceneView(model: mount.model, bundleDirectory: mount.bundleDirectory)
                    }
                    .frame(width: Metrics.sidebarWidth)
                    .padding(.vertical, Metrics.space2)
                    .background(RoundedRectangle(cornerRadius: Metrics.itemCornerRadius + 2, style: .continuous).fill(colors.background))
                }
            } else {
                Color.clear.frame(height: Metrics.sidebarRowHeight)
            }
        }
        .onAppear(perform: start)
        .onDisappear(perform: stop)
        .onChange(of: model.state(of: listing.id)?.isActive) { _, _ in
            stop()
            start()
        }
    }

    private func start() {
        guard mount == nil, let bundle = listing.bundle else { return }
        let host = model.state(of: listing.id)?.isActive == true ? model.host : model.previewHost
        self.host = host
        mount = host.mount(bundle.manifest, directory: bundle.directory, contribution: contribution,
                           surface: contribution.kind == .statusItem ? "statusItem" : "sidebarSection")
    }

    private func stop() {
        if let mount { host?.unmount(mount) }
        mount = nil
        host = nil
    }
}
