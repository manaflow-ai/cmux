import CmuxNextDesign
import SwiftUI

/// A live preview of one implementation: the supervisor runs the app and
/// streams its scene. An active app mounts normally (its real data and
/// grant); any other mounts as a preview (`context.preview`: no grants,
/// sample data). Re-mounts when the app's active state changes.
struct AppLivePreview: View {
    let model: AppStoreModel
    let listing: AppStoreListing
    let implementation: AppImplementation
    @State private var mount: AppMount?
    @Environment(\.appSceneColors) private var colors

    var body: some View {
        Group {
            if let mount {
                if implementation.isStatusItem {
                    AppStatusItemFrame { AppSceneView(model: mount.model, bundleDirectory: mount.bundleDirectory).fixedSize() }
                } else {
                    AppSectionFrame(look: model.look, title: implementation.title?.resolved() ?? listing.name.resolved(),
                                    symbol: implementation.symbol, icon: listing.icon, bundleDirectory: listing.bundleDirectory) {
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
        guard mount == nil else { return }
        let active = model.state(of: listing.id)?.isActive == true
        mount = model.client.mount(listing.id, implementation: implementation,
                                   surface: implementation.isStatusItem ? "statusItem" : "sidebarSection", preview: !active)
    }

    private func stop() {
        if let mount { model.client.unmount(mount) }
        mount = nil
    }
}
