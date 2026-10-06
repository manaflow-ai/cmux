public import AppKit
public import CmuxNextDesign
import SwiftUI

/// The App Store window (palette "App Store", `appStore.show`): one window
/// per app, SwiftUI in an NSHostingView like Settings, colors from the
/// theme scope of the window it was opened from; no-activate launches place
/// it without taking the keyboard (`WindowPlacement`).
public final class AppStoreWindowController: NSWindowController, NSWindowDelegate {
    public let model: AppStoreModel
    /// Runs once after the window closed (the owner releases it).
    public var onClose: (() -> Void)?
    private var scope: ThemeScope = .app

    public init(model: AppStoreModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = AppsStrings.windowTitle
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 720, height: 460)
        window.identifier = NSUserInterfaceItemIdentifier("cmux.appStore")
        window.setFrameAutosaveName("cmux.appStore")
        super.init(window: window)
        window.delegate = self
        window.install(kind: .appStore, content: AppStoreContentView(model: model), scope: scope)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Draws in `scope` (the room theme of the window it was opened from).
    public func setThemeScope(_ scope: ThemeScope) {
        self.scope = scope
        guard let window else { return }
        scope.adopt(window)
        (window.installedContent as? AppStoreContentView)?.resolveColors()
    }

    /// Shows the window; `appID` opens that listing, `installed` the Installed tab.
    public func present(appID: String? = nil, installed: Bool = false) {
        model.present(appID: appID, installed: installed)
        guard let window else { return }
        scope.adopt(window)
        WindowPlacement.present(window)
    }

    public func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

extension AppStoreModel {
    /// The App Store content as one self-contained view: the window hosts it
    /// today; a pane (internal page tab) hosts the same view once the shared
    /// page mechanism lands.
    /// `inPane`: hosted in a pane (internal page tab): no traffic-light inset.
    public func makeContentView(inPane: Bool = false) -> NSView {
        AppStoreContentView(model: self, inPane: inPane)
    }
}

/// The App Store content: one self-contained view that resolves the scene
/// colors in its window's theme scope. The window hosts it today; a pane
/// (internal page tab) hosts the same view once the shared page mechanism lands.
final class AppStoreContentView: NSHostingView<AnyView> {
    private let appearanceModel = AppSceneAppearance()

    init(model: AppStoreModel, inPane: Bool = false) {
        let appearance = appearanceModel
        super.init(rootView: AnyView(AppSceneThemedRoot(appearance: appearance) { AppStoreRootView(model: model, inPane: inPane) }))
    }

    @available(*, unavailable)
    @MainActor required init(rootView: AnyView) { fatalError("init(rootView:) is not supported") }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolveColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveColors()
    }

    func resolveColors() {
        // The window background is its kind's (`NSWindow.install`).
        appearanceModel.update(from: self)
    }
}
