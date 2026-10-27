import AppKit
import CmuxNextWakeups
import Observation

/// The right sidebar's section views, by mode: the app registers Vault, Feed,
/// Dock and Cloud; the file explorer registers Files and Find. A mode without
/// a provider has no button and its switch action refuses.
@MainActor
@Observable
final class RightSidebarSections {
    /// Makes one window's view of a section (once per window; the view is kept).
    typealias Provider = @MainActor (WindowController) -> NSView

    @ObservationIgnored private var providers: [RightSidebarMode: Provider] = [:]
    // memory: fixed one SF Symbol image per RightSidebarMode case (6), a few KB each
    /// The section buttons' SF Symbol images, made off the main thread by ``buildIcons(_:)``: CoreUI decodes
    /// each symbol's vectors when its image is made, which cost the first Focus Right Sidebar 47 ms in its turn.
    @ObservationIgnored private var icons: [RightSidebarMode: NSImage] = [:]
    /// Every registered mode's icon is made (tests and the debug report read it).
    private(set) var iconsReady = false
    /// The launch's scheduler the icon build posts on; nil in a host with no launch (tests), which makes them at once.
    @ObservationIgnored private let startup: StartupScheduler?
    /// Makes one SF Symbol image; called off the main thread (NSImage is thread-safe to make).
    @ObservationIgnored private let symbolImage: @Sendable (String) -> NSImage?
    @ObservationIgnored private var buildPosted = false
    @ObservationIgnored private var readyWaiters: [@MainActor ([RightSidebarMode: NSImage]) -> Void] = []

    /// - Parameters:
    ///   - startup: The launch's scheduler (the icon build is one of its lane posts); nil makes the icons on main.
    ///   - symbolImage: Makes an SF Symbol image by name (tests count the calls).
    init(startup: StartupScheduler? = nil,
         symbolImage: @escaping @Sendable (String) -> NSImage? = { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }) {
        self.startup = startup
        self.symbolImage = symbolImage
    }

    func register(_ mode: RightSidebarMode, _ provider: @escaping Provider) {
        providers[mode] = provider
    }

    /// The modes with a section, in mode bar order.
    var modes: [RightSidebarMode] { RightSidebarMode.allCases.filter { providers[$0] != nil } }

    func makeView(_ mode: RightSidebarMode, for window: WindowController) -> NSView? {
        providers[mode]?(window)
    }

    /// The icon of `mode`'s button once the build landed, else nil: a panel shows an empty button until
    /// ``whenIconsReady(_:)`` fills it, so no main turn decodes a symbol.
    func icon(_ mode: RightSidebarMode) -> NSImage? { icons[mode] }

    /// Calls `body` with the icons once the build landed: now when it did.
    func whenIconsReady(_ body: @escaping @MainActor ([RightSidebarMode: NSImage]) -> Void) {
        if iconsReady { return body(icons) }
        readyWaiters.append(body)
    }

    /// Posts the icon build once, on the cpu lane at idle priority, at `priority`: afterStartup from the launch's
    /// `RightSidebar.prewarm` post, afterFirstFrame from a panel (a panel restored visible in the launch window
    /// fills right after the first frame). The images land on main at the same priority. This is Chrome's
    /// `AfterStartupTaskUtils::PostTask` with a background destination runner
    /// (chrome/browser/after_startup_task_utils.cc). With no scheduler the icons are made now.
    ///
    /// - Parameter priority: When the build runs, if it is not posted yet.
    func buildIcons(_ priority: StartupPriority) {
        guard !buildPosted else { return }
        buildPosted = true
        let modes = self.modes
        let symbolImage = self.symbolImage
        guard let startup else { return land(modes.compactMap { mode in symbolImage(mode.symbol).map { (mode, $0) } }) }
        startup.post(priority, "RightSidebar.icons", on: .lane(.cpu, .idle)) { [weak self] in
            let made = modes.compactMap { mode in symbolImage(mode.symbol).map { (mode, $0) } }
            startup.post(priority, "RightSidebar.icons.land", on: .main) { [weak self] in self?.land(made) }
        }
    }

    private func land(_ made: [(RightSidebarMode, NSImage)]) {
        for (mode, image) in made { icons[mode] = image }
        iconsReady = true
        let waiting = readyWaiters
        readyWaiters = []
        for body in waiting { body(icons) }
    }
}
