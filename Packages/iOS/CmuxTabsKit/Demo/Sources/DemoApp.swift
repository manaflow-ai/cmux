import CmuxTabsKit
import SwiftUI
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        true
    }
}

/// UIKit scene so the root is a `TabsKitHostingController`, which applies
/// the status bar style each tab asks for.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private let tabs = DemoTabs()

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = TabsKitHostingController(rootView: DemoRoot(tabs: tabs))
        window.makeKeyAndVisible()
        self.window = window
    }
}

/// `-showGrid` on launch opens the tab grid once the first page has
/// loaded (screenshots), through `TabsView`'s overview binding.
struct DemoRoot: View {
    let tabs: DemoTabs
    @State private var showGrid = false
    @State private var wantsGrid = ProcessInfo.processInfo.arguments.contains("-showGrid")

    var body: some View {
        TabsView(source: tabs, isShowingOverview: $showGrid)
            .onChange(of: tabs.thumbnail(for: tabs.activeTabID ?? "") != nil) { _, ready in
                if ready, wantsGrid {
                    wantsGrid = false
                    showGrid = true
                }
            }
    }
}
