import AppKit
import CmuxCloud
import SwiftUI

/// Shows "Introducing cmux Cloud" once: on first launch, and for existing users
/// on the first launch after the update that ships it (they have no seen key
/// yet either). Debug builds can reopen it from Help.
@MainActor
final class CloudWelcomeWindowController: NSObject, NSWindowDelegate {
    static let seenDefaultsKey = "cmux.cloud.welcome.seen"

    private var window: NSWindow?
    /// Debug (Help menu): hides the "new" badge in every layout.
    private(set) var hidesNewBadge = false
    private var lastSliderShowsFeatureList = false
    private var lastSliderListUsesDots = false
    private weak var lastParent: NSWindow?
    /// Launch presentation is considered once, at the first main window. A
    /// window opened later (Cmd+N an hour in) must not pop the welcome up just
    /// because remote flags arrived since; an unseen welcome waits for next launch.
    private var didConsiderLaunchPresentation = false

    /// Cloud has to be offered on this Mac and still be off; `seen` makes it once.
    nonisolated static func shouldPresentAutomatically(
        seen: Bool,
        cloudAvailable: Bool,
        cloudEnabled: Bool
    ) -> Bool {
        !seen && cloudAvailable && !cloudEnabled
    }

    /// Presents at launch when it applies, and marks it seen on the way so a
    /// quit or crash while it is open does not show it again.
    func presentIfNeeded(over parent: NSWindow?, defaults: UserDefaults = .standard) {
        guard !didConsiderLaunchPresentation else { return }
        didConsiderLaunchPresentation = true
        guard Self.shouldPresentAutomatically(
            seen: defaults.bool(forKey: Self.seenDefaultsKey),
            cloudAvailable: CloudMachinesFeature.isAvailable,
            cloudEnabled: CloudMachinesFeature.isEnabled
        ) else { return }
        defaults.set(true, forKey: Self.seenDefaultsKey)
        present(over: parent)
    }

    /// The slider layout is a debug choice while it is designed; launch uses the default.
    func present(over parent: NSWindow?, sliderShowsFeatureList: Bool = false, sliderListUsesDots: Bool = false) {
        window?.close()
        lastSliderShowsFeatureList = sliderShowsFeatureList
        lastSliderListUsesDots = sliderListUsesDots
        lastParent = parent
        let window = makeWindow(sliderShowsFeatureList: sliderShowsFeatureList, sliderListUsesDots: sliderListUsesDots)
        self.window = window
        position(window, over: parent)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Debug: flips the badge and reopens the welcome in the layout last shown.
    func toggleNewBadge() {
        hidesNewBadge.toggle()
        present(
            over: lastParent ?? NSApp.mainWindow,
            sliderShowsFeatureList: lastSliderShowsFeatureList,
            sliderListUsesDots: lastSliderListUsesDots
        )
    }

    private func makeWindow(sliderShowsFeatureList: Bool, sliderListUsesDots: Bool) -> NSWindow {
        let rootView = CloudWelcomeAccountView(
            accountFlow: AppDelegate.shared?.auth?.accountFlow,
            sliderShowsFeatureList: sliderShowsFeatureList,
            sliderListUsesDots: sliderListUsesDots,
            showsNewBadge: !hidesNewBadge,
            onNotNow: { [weak self] in self?.dismiss() },
            onNext: { [weak self] step in self?.perform(step) }
        )
        let hosting = NSHostingView(rootView: rootView)
        // The content clears the traffic lights with its own top padding, so it
        // needs no titlebar safe area. Tracking it also loops in the app: the
        // hosting view keeps invalidating its safe area and constraints until
        // AppKit aborts (too many Update Constraints passes, 2026-10-04).
        hosting.safeAreaRegions = []
        let size = hosting.fittingSize
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.cloud.welcome")
        window.title = String(localized: "cloud.welcome.title", defaultValue: "Introducing cmux cloud")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        // The glass in CloudWelcomeView is the window's background.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.contentView = hosting
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            // The window is the glass: content goes inside it, edge to edge, and the
            // window's own frame rounds the corners.
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.contentView = hosting
            window.contentView = glass
        }
        #endif
        window.delegate = self
        return window
    }

    /// A third of the way down the parent window, centered across it, like
    /// NSWindow.center() places windows on the screen.
    private func position(_ window: NSWindow, over parent: NSWindow?) {
        guard let parent, parent.isVisible else {
            window.center()
            return
        }
        let size = window.frame.size
        let frame = parent.frame
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.maxY - (frame.height - size.height) / 3 - size.height
        )
        window.setFrameOrigin(origin)
    }

    private func perform(_ step: CloudWelcomeNextStep) {
        dismiss()
        let app = AppDelegate.shared
        switch step {
        case .signIn:
            _ = app?.focusRightSidebarInActiveMainWindow(mode: .machines)
            app?.auth?.accountFlow.startSignIn()
        case .upgrade:
            ProUpgradePresenter.present(source: .cloudWelcome)
        case .enable:
            _ = app?.focusRightSidebarInActiveMainWindow(mode: .machines)
            app?.cloudActivationCoordinator.enable()
        case .openCloud:
            _ = app?.focusRightSidebarInActiveMainWindow(mode: .machines)
        }
    }

    func dismiss() {
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

/// Feeds the account's sign-in and plan into ``CloudWelcomeView`` and asks for
/// the plan once on show, so the view itself stays free of app objects.
private struct CloudWelcomeAccountView: View {
    let accountFlow: HostAccountFlow?
    let sliderShowsFeatureList: Bool
    let sliderListUsesDots: Bool
    let showsNewBadge: Bool
    let onNotNow: () -> Void
    let onNext: (CloudWelcomeNextStep) -> Void

    var body: some View {
        CloudWelcomeView(
            nextStep: CloudWelcomeNextStep.resolve(
                isAuthenticated: accountFlow?.isAuthenticated == true,
                isPlanKnown: accountFlow?.hasLoadedBillingPlan == true,
                isPro: accountFlow?.isProActive == true
            ),
            onNotNow: onNotNow,
            onNext: onNext,
            sliderShowsFeatureList: sliderShowsFeatureList,
            sliderListUsesDots: sliderListUsesDots,
            showsNewBadge: showsNewBadge
        )
        .task {
            // The plan decides between Upgrade and Enable; ask once on show.
            if accountFlow?.isAuthenticated == true {
                await accountFlow?.refreshBillingPlan()
            }
        }
    }
}
