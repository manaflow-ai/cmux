import AppKit

/// One window's Home: shown in place of the workspace while
/// `WindowState.showsHome` is set (client view state; never persisted, never
/// part of a workspace id). The view is created on first show and kept for
/// the window's life, so its scroll position and draft survive leaving Home.
@MainActor
final class HomePresenter {
    private(set) var view: HomeHostView?
    private(set) var isShown = false
    private unowned let services: AppServices
    private unowned let state: WindowState

    init(services: AppServices, state: WindowState) {
        self.services = services
        self.state = state
    }

    /// Shows Home in `root` and makes the composer the window's first responder.
    func show(in root: WindowRootView) {
        if isShown, let view, view.superview != nil { return }
        let view = view ?? HomeHostView(services: services, state: state)
        self.view = view
        root.show(view)
        root.titlebar.title = HomeStrings.title
        isShown = true
        services.home.homeDidOpen()
        // First responder only: a never-key test window still never takes the keyboard.
        view.focusComposer()
    }

    /// Home left the window; the caller shows the workspace.
    func hide() {
        isShown = false
    }
}
