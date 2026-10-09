import AppKit
import CmuxCloud
import SwiftUI

/// Shows the 0.65.1 Cloud welcome once for users who have Cloud available and
/// have not enabled it yet. Debug builds can reopen it from Help.
@MainActor
final class CloudWelcomeWindowController: NSObject, NSWindowDelegate {
    /// The welcome is a release announcement, rather than a permanent prompt.
    /// Versioning the marker lets a later announcement be shown once without
    /// bringing back an older welcome that a user already dismissed.
    nonisolated static let campaignVersion = "0.65.1"
    static let seenVersionDefaultsKey = "cmux.cloud.welcome.seenVersion"

    private var window: NSWindow?
    /// Launch presentation is considered once, at the first main window. A
    /// window opened later (Cmd+N an hour in) must not pop the welcome up just
    /// because remote flags arrived since; an unseen welcome waits for next launch.
    private var didConsiderLaunchPresentation = false

    /// Cloud has to be offered on this Mac and still be off. The campaign only
    /// runs in its target release, and its version marker makes it one-time.
    nonisolated static func shouldPresentAutomatically(
        seenVersion: String?,
        appVersion: String,
        cloudAvailable: Bool,
        cloudEnabled: Bool,
        isDebugBuild: Bool = false,
        isRunningUnderXCTest: Bool = false,
        isUITestMode: Bool = false
    ) -> Bool {
        guard !isDebugBuild, !isRunningUnderXCTest, !isUITestMode else { return false }
        return appVersion == campaignVersion
            && seenVersion != campaignVersion
            && cloudAvailable
            && !cloudEnabled
    }

    /// Records that this release's announcement has been considered. The
    /// caller writes this before presenting so a crash or quit cannot replay it.
    nonisolated static func markCampaignSeen(in defaults: UserDefaults) {
        defaults.set(campaignVersion, forKey: seenVersionDefaultsKey)
    }

    /// Presents at launch when it applies, and marks it seen on the way so a
    /// quit or crash while it is open does not show it again.
    func presentIfNeeded(over parent: NSWindow?, defaults: UserDefaults = .standard) {
        guard !didConsiderLaunchPresentation else { return }
        didConsiderLaunchPresentation = true
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard Self.shouldPresentAutomatically(
            seenVersion: defaults.string(forKey: Self.seenVersionDefaultsKey),
            appVersion: appVersion,
            cloudAvailable: CloudMachinesFeature.isAvailable,
            cloudEnabled: CloudMachinesFeature.isEnabled
        ) else { return }
        Self.markCampaignSeen(in: defaults)
        present(over: parent)
    }

    /// Help and launch share the same feature-list layout.
    func present(over parent: NSWindow?, sliderShowsFeatureList: Bool = true, sliderListUsesDots: Bool = false) {
        window?.close()
        let window = makeWindow(sliderShowsFeatureList: sliderShowsFeatureList, sliderListUsesDots: sliderListUsesDots)
        self.window = window
        position(window, over: parent)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(sliderShowsFeatureList: Bool, sliderListUsesDots: Bool) -> NSWindow {
        let rootView = CloudWelcomeAccountView(
            accountFlow: AppDelegate.shared?.auth?.accountFlow,
            sliderShowsFeatureList: sliderShowsFeatureList,
            sliderListUsesDots: sliderListUsesDots,
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
        window.title = String(localized: "cloud.welcome.title", defaultValue: "Your work, wherever you go")
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
            sliderListUsesDots: sliderListUsesDots
        )
        .task {
            // The plan decides between Upgrade and Enable; ask once on show.
            if accountFlow?.isAuthenticated == true {
                await accountFlow?.refreshBillingPlan()
            }
        }
    }
}
