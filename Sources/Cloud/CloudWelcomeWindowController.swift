import AppKit
import CmuxSettings
import SwiftUI

/// Whether a Cloud creation action (New Cloud Workspace, New Cloud Machine)
/// may run, or must first introduce Cloud with the welcome card, whose next
/// step offers Enable or Upgrade, instead of giving no response.
enum CloudCreationGate: Equatable {
    case proceed
    case introduceCloud

    /// - Parameters:
    ///   - isAvailable: Managed policy allows Cloud. A policy-disabled Mac
    ///     keeps the action's existing handling; the welcome is not for it.
    ///   - isEnabled: The local first-use activation is on.
    ///   - canRunCloudOperations: The Cloud operation controller admits work
    ///     (enabled and signed in), or nil before app composition.
    ///   - isAuthInProgress: A session restore or sign-in is still settling,
    ///     so signed out is not yet a real answer.
    static func resolve(
        isAvailable: Bool,
        isEnabled: Bool,
        canRunCloudOperations: Bool?,
        isAuthInProgress: Bool
    ) -> CloudCreationGate {
        guard isAvailable else { return .proceed }
        guard isEnabled else { return .introduceCloud }
        return canRunCloudOperations == false && !isAuthInProgress ? .introduceCloud : .proceed
    }
}

/// Shows the Cloud welcome campaign once on its eligible releases (0.65.1 and
/// 0.65.2), whether Cloud is on or off, unless MDM blocks Cloud. Debug builds
/// can reopen it from Help.
@MainActor
final class CloudWelcomeWindowController: NSObject, NSWindowDelegate {
    /// The welcome is a release announcement, rather than a permanent prompt.
    /// The persisted marker holds this campaign id, so a user sees the campaign
    /// once across all of its releases, and a later campaign with a new id is
    /// shown once without bringing back one a user already dismissed. The id is
    /// the release that first shipped the campaign, which is what 0.65.1 wrote.
    nonisolated static let campaignVersion = "0.65.1"
    /// App versions that automatically show this campaign. Add a release here
    /// to extend the campaign; keep ``campaignVersion`` so earlier viewers are
    /// not shown it again.
    nonisolated static let campaignAppVersions: Set<String> = ["0.65.1", "0.65.2"]
    nonisolated static let seenVersionDefaultsKey = "cmux.cloud.welcome.seenVersion"

    private var window: NSWindow?
    /// The Cloud action that opened this card, run again once Enable succeeds.
    private var onEnabled: (@MainActor () -> Void)?
    /// Launch presentation is considered once, at the first main window. A
    /// window opened later (Cmd+N an hour in) must not pop the welcome up just
    /// because MDM policy changed since; an unseen welcome waits for next launch.
    private var didConsiderLaunchPresentation = false

    /// Cloud's on/off setting does not affect the announcement. Only managed
    /// DisableCloud policy excludes users from this one-time release campaign,
    /// which shows on any version in ``campaignAppVersions`` until the marker
    /// records ``campaignVersion``.
    nonisolated static func shouldPresentAutomatically(
        defaults: UserDefaults,
        appVersion: String,
        policy: ManagedDevicePolicy,
        isDebugBuild: Bool = false,
        isRunningUnderXCTest: Bool = false,
        isUITestMode: Bool = false
    ) -> Bool {
        guard !isDebugBuild, !isRunningUnderXCTest, !isUITestMode else { return false }
        return campaignAppVersions.contains(appVersion)
            && defaults.string(forKey: seenVersionDefaultsKey) != campaignVersion
            && !policy.isEnforced(.disableCloud)
    }

    /// Records that this campaign's announcement has been considered, on any of
    /// its releases. The caller writes this before presenting so a crash or
    /// quit cannot replay it.
    nonisolated static func markCampaignSeen(in defaults: UserDefaults) {
        defaults.set(campaignVersion, forKey: seenVersionDefaultsKey)
    }

    /// Presents at launch when it applies, and marks it seen on the way so a
    /// quit or crash while it is open does not show it again.
    func presentIfNeeded(over parent: NSWindow?, defaults: UserDefaults = .standard) {
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let environment = ProcessInfo.processInfo.environment
        #if DEBUG
        let isDebugBuild = true
        #else
        let isDebugBuild = false
        #endif
        guard claimLaunchPresentation(
            defaults: defaults,
            appVersion: appVersion,
            policy: ManagedDevicePolicy(),
            isDebugBuild: isDebugBuild,
            isRunningUnderXCTest: MacSentryStartupPolicy.isRunningUnderXCTest(environment: environment),
            isUITestMode: environment["CMUX_UI_TEST_MODE"] == "1"
        ) else { return }
        present(over: parent)
    }

    /// Claims the release announcement synchronously before creating its window.
    /// Overlapping main-window callbacks and a later launch share the persisted
    /// marker; an ineligible first window still consumes this launch's decision.
    func claimLaunchPresentation(
        defaults: UserDefaults,
        appVersion: String,
        policy: ManagedDevicePolicy,
        isDebugBuild: Bool = false,
        isRunningUnderXCTest: Bool = false,
        isUITestMode: Bool = false
    ) -> Bool {
        guard !didConsiderLaunchPresentation else { return false }
        didConsiderLaunchPresentation = true
        guard Self.shouldPresentAutomatically(
            defaults: defaults,
            appVersion: appVersion,
            policy: policy,
            isDebugBuild: isDebugBuild,
            isRunningUnderXCTest: isRunningUnderXCTest,
            isUITestMode: isUITestMode
        ) else { return false }
        Self.markCampaignSeen(in: defaults)
        return true
    }

    /// Help deliberately reopens the same headline card without consuming or
    /// resetting the automatic release announcement's persistence marker.
    func present(
        over parent: NSWindow?,
        sliderShowsFeatureList: Bool = true,
        sliderListUsesDots: Bool = false,
        posterHeadline: String? = CloudWelcomeView.headline,
        posterShowsTitle: Bool = true,
        posterShowsIcon: Bool = true,
        showsNewBadge: Bool = false,
        footerHasNotNow: Bool = false,
        onEnabled: (@MainActor () -> Void)? = nil
    ) {
        window?.close()
        self.onEnabled = onEnabled
        let window = makeWindow(
            sliderShowsFeatureList: sliderShowsFeatureList,
            sliderListUsesDots: sliderListUsesDots,
            posterHeadline: posterHeadline,
            posterShowsTitle: posterShowsTitle,
            posterShowsIcon: posterShowsIcon,
            showsNewBadge: showsNewBadge,
            footerHasNotNow: footerHasNotNow
        )
        self.window = window
        position(window, over: parent)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(
        sliderShowsFeatureList: Bool,
        sliderListUsesDots: Bool,
        posterHeadline: String?,
        posterShowsTitle: Bool,
        posterShowsIcon: Bool,
        showsNewBadge: Bool,
        footerHasNotNow: Bool
    ) -> NSWindow {
        let shortcut = KeyboardShortcutSettings.shortcut(for: .newCloudMachine)
        let rootView = CloudWelcomeAccountView(
            accountFlow: AppDelegate.shared?.auth?.accountFlow,
            sliderShowsFeatureList: sliderShowsFeatureList,
            sliderListUsesDots: sliderListUsesDots,
            posterHeadline: posterHeadline,
            newMachineShortcut: shortcut.isUnbound ? nil : shortcut.displayString,
            posterShowsTitle: posterShowsTitle,
            posterShowsIcon: posterShowsIcon,
            showsNewBadge: showsNewBadge,
            footerHasNotNow: footerHasNotNow,
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
        window.title = String(localized: "cloud.welcome.title.eyebrow", defaultValue: "cmux cloud")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        // The glass in CloudWelcomeView is the window's background.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        if sliderShowsFeatureList {
            // The launch card's own × (and Escape) is Not Now; Cmd+W still closes.
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(kind)?.isHidden = true
            }
        }
        window.contentView = hosting
        if sliderShowsFeatureList {
            // The launch card is opaque: the window takes the card's colour.
            window.isOpaque = true
            window.backgroundColor = CloudWelcomeView.launchCardColor
            // Hosted in a plain container: as the window's own content view the
            // hosting view reserves the hidden titlebar's height above the clip.
            let container = NSView(frame: NSRect(origin: .zero, size: size))
            hosting.frame = container.bounds
            hosting.autoresizingMask = [.width, .height]
            container.addSubview(hosting)
            window.contentView = container
        }
        #if compiler(>=6.2)
        if !sliderShowsFeatureList, #available(macOS 26.0, *) {
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
        let onEnabled = self.onEnabled
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
            guard let activation = app?.cloudActivationCoordinator else { return }
            activation.enable()
            if let onEnabled {
                Task { @MainActor in await Self.resume(onEnabled, after: activation) }
            }
        case .openCloud:
            _ = app?.focusRightSidebarInActiveMainWindow(mode: .machines)
        }
    }

    /// Continues the Cloud action that opened the card once activation has
    /// finished preparing, and only if it ended enabled. A cancel and retry
    /// while waiting replaces the task, so wait for whichever is current.
    static func resume(
        _ action: @MainActor () -> Void,
        after activation: CloudActivationCoordinator
    ) async {
        while let task = activation.activationTask {
            await task.value
        }
        guard activation.state == .enabled, !activation.isPreparing else { return }
        action()
    }

    func dismiss() {
        window?.close()
        window = nil
        onEnabled = nil
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        onEnabled = nil
    }
}

/// Feeds the account's sign-in and plan into ``CloudWelcomeView`` and asks for
/// the plan once on show, so the view itself stays free of app objects.
private struct CloudWelcomeAccountView: View {
    let accountFlow: HostAccountFlow?
    let sliderShowsFeatureList: Bool
    let sliderListUsesDots: Bool
    let posterHeadline: String?
    let newMachineShortcut: String?
    let posterShowsTitle: Bool
    let posterShowsIcon: Bool
    let showsNewBadge: Bool
    let footerHasNotNow: Bool
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
            posterHeadline: posterHeadline,
            newMachineShortcut: newMachineShortcut,
            posterShowsTitle: posterShowsTitle,
            posterShowsIcon: posterShowsIcon,
            showsNewBadge: showsNewBadge,
            footerHasNotNow: footerHasNotNow
        )
        .task {
            // The plan decides between Upgrade and Enable; ask once on show.
            if accountFlow?.isAuthenticated == true {
                await accountFlow?.refreshBillingPlan()
            }
        }
    }
}
