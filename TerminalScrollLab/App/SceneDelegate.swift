import UIKit
import CmuxMobileTerminal

@MainActor
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        do {
            let runtime = try GhosttyRuntime.shared()
            window.rootViewController = TerminalScrollViewController(runtime: runtime)
        } catch {
            window.rootViewController = TerminalRuntimeErrorViewController(error: error)
        }
        window.makeKeyAndVisible()
        self.window = window
    }
}
