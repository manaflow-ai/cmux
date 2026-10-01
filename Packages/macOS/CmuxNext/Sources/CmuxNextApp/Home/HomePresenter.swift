import AppKit

/// One window's Home: shown in place of the workspace while
/// `WindowState.showsHome` is set. The workspace underneath stays mounted
/// (not parked), so leaving Home returns to it in one frame. The page is
/// created on first show and kept for the window's life.
@MainActor
final class HomePresenter {
    private(set) var view: HomeView?
    private(set) var isShown = false
    private let url: URL

    init(url: URL = HomeLocation.url()) {
        self.url = url
    }

    /// Shows Home in `root` and gives its page the keyboard.
    func show(in root: WindowRootView) {
        // The window re-checks what to show on every workspace change; only
        // the first show takes the title and the keyboard.
        if isShown, let view, view.superview != nil { return }
        let view = view ?? HomeView(url: url)
        self.view = view
        root.show(view)
        root.titlebar.title = HomeStrings.title
        isShown = true
        view.window?.makeFirstResponder(view.webView)
    }

    /// Notes that Home left the window; the caller shows the workspace.
    func hide() {
        isShown = false
    }
}
