#if os(iOS)
import CmuxMobileLinkFFI
import CmuxScreenKitUI
public import UIKit

/// The app is portrait on a phone's screen everywhere but a Mac's screen,
/// which turns with the phone (or as its options menu locks it), and a
/// workspace's tab pages (terminal, browser, agent chat, simulator), which
/// turn with the phone (Leo, 2026-11-23: "why do we not have a horizontal
/// mode?"): a swipe to the next tab or an address-bar edit keeps the phone
/// sideways. An unfolded
/// foldable's wide, nearly square screen ("iPhone Duo") turns everywhere, as
/// an iPad's does: people hold it either way. The app delegate returns
/// ``allowed(in:)`` from `application(_:supportedInterfaceOrientationsFor:)`.
@MainActor
public final class ScreenSharingOrientation {
    public static let shared = ScreenSharingOrientation()

    /// Starts the device's orientation reports, so `update()` reads a phone
    /// already held sideways (`UIDevice.current.orientation` is `.unknown`
    /// until something starts them).
    init() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    }

    /// Whether a Mac's screen is on screen.
    public private(set) var isPresenting = false

    /// Whether a terminal page is on screen and settled.
    public private(set) var isShowingTerminal = false

    /// Workspace tab pages full screen (not zoomed out to the grid), by tab id.
    private var tabPages: Set<String> = []

    /// Whether a page that turns with the phone is on screen.
    public var isShowingTurningPage: Bool { isShowingTerminal || !tabPages.isEmpty }

    /// The screen's own choice (`ScreenOrientation.shared`) while a Mac's screen
    /// shows, else the window's resting orientations.
    public func allowed(in window: UIWindow?) -> UIInterfaceOrientationMask {
        isPresenting ? ScreenOrientation.shared.allowed
            : Self.resting(windowSize: Self.size(of: window), showingTerminal: isShowingTurningPage)
    }

    /// The window's size, or its scene's when the system asks with no window.
    private static func size(of window: UIWindow?) -> CGSize {
        if let window { return window.bounds.size }
        let scene = UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first
        return scene?.effectiveGeometry.coordinateSpace.bounds.size ?? .zero
    }

    /// Portrait on a phone's screen; any orientation but upside down (as the
    /// Info.plist lists) on an unfolded foldable's, or on a terminal page.
    nonisolated static func resting(windowSize size: CGSize, showingTerminal: Bool = false) -> UIInterfaceOrientationMask {
        showingTerminal || isUnfolded(windowSize: size) ? .allButUpsideDown : .portrait
    }

    /// A terminal page came on screen and settled (it turns with the phone),
    /// or left (the app goes back to portrait on a phone).
    public func terminalShown(_ shown: Bool) {
        guard shown != isShowingTerminal else { return }
        let was = isShowingTurningPage
        isShowingTerminal = shown
        if was != isShowingTurningPage { update() }
    }

    /// A workspace tab page is (or is no longer) full screen: it turns with
    /// the phone like a terminal page, so moving between tabs keeps the turn.
    public func tabPage(_ id: String, shows: Bool) {
        let was = isShowingTurningPage
        if shows { tabPages.insert(id) } else { tabPages.remove(id) }
        if was != isShowingTurningPage { update() }
    }

    /// Whether a window this size is an unfolded foldable's: Rust's
    /// `window_layout` (its `UNFOLDED_SHORT_SIDE`, 600 pt), the same rule that
    /// gives the shell two panes, so orientation and layout never disagree.
    public nonisolated static func isUnfolded(windowSize size: CGSize) -> Bool {
        windowLayout(width: Double(size.width), height: Double(size.height)).unfolded
    }

    /// The window crossed between a phone's size and an unfolded foldable's: a
    /// fold turns the app back to portrait, an unfold lets it turn.
    public func foldChanged() {
        update()
    }

    /// The screen appeared: the phone may turn.
    func begin() {
        isPresenting = true
        update()
    }

    /// The screen went away: back to the window's resting orientations.
    func end() {
        guard isPresenting else { return }
        isPresenting = false
        // A lock chosen in this session's menu ends with it.
        ScreenOrientation.shared.lock(.auto)
        update()
    }

    private func update() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                var controller = window.rootViewController
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                while let presented = controller?.presentedViewController {
                    presented.setNeedsUpdateOfSupportedInterfaceOrientations()
                    controller = presented
                }
            }
            guard !isPresenting else { continue }
            let size = scene.effectiveGeometry.coordinateSpace.bounds.size
            if Self.resting(windowSize: size, showingTerminal: isShowingTurningPage) == .portrait {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait), errorHandler: Self.ignoreGeometryError)
            } else if size.height > size.width, let sideways = Self.interface(for: UIDevice.current.orientation) {
                // Allowed to turn while the phone is already held sideways (back from a portrait
                // screen): UIKit waits for the next device turn, so ask for it now.
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: sideways), errorHandler: Self.ignoreGeometryError)
            }
        }
    }

    /// The interface orientation a sideways-held phone shows (a device turned left
    /// shows its interface turned right), or nil when the phone is not sideways.
    nonisolated static func interface(for device: UIDeviceOrientation) -> UIInterfaceOrientationMask? {
        switch device {
        case .landscapeLeft: .landscapeRight
        case .landscapeRight: .landscapeLeft
        default: nil
        }
    }

    /// What a refused portrait request does: nothing (the next `update()` asks again). UIKit calls
    /// it on a background queue, so it is not main-actor isolated: as an inline closure in this
    /// `@MainActor` class it inherited the isolation and trapped there (EXC_BREAKPOINT in
    /// `dispatch_assert_queue`, AllUIStatesChatFeedCaptureUITests testFeed, step aed9d983).
    nonisolated static let ignoreGeometryError: @Sendable (any Error) -> Void = { _ in }
}
#endif
