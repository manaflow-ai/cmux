import AppKit
import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDaemonService
import CmuxNextFocusUI
import CmuxNextPages
import CmuxNextRemoteLocalhostService
import CmuxNextSettingsWindow
import Foundation

/// The Settings page and its transient sign-in browser share the current page tab or top page.
@MainActor
final class SettingsSignInPane: NSSplitView, NSSplitViewDelegate, BrowserTabDelegate {
    private unowned let services: AppServices
    private(set) var settingsPage: PageWebView?
    private let settingsContent = NSView()
    private let browserContent = NSView()
    private let viewport = NSView()
    private lazy var header = SettingsSignInHeader(reload: { [weak self] in self?.currentTab?.reload() },
                                                   close: { [weak self] in self?.close() })

    private static let defaultBrowserWidth: CGFloat = 480
    private static let minimumBrowserWidth: CGFloat = 320
    private static let minimumSettingsWidth: CGFloat = 420
    private weak var expandedWindow: NSWindow?
    private var originalFrame: NSRect?
    private var originalMinimum: NSSize?
    private var owner: String?
    private var openingURL: URL?
    private var pending = UUID()
    private var tabs: [any BrowserTab] = []
    private var currentTab: (any BrowserTab)? { tabs.last }
    private var addressWatch: Task<Void, Never>?
    private var remote: (daemon: DaemonService, port: UInt16)?
    private var redirectTask: Task<Void, Never>?

    init(services: AppServices) {
        self.services = services
        super.init(frame: .zero)
        isVertical = true
        dividerStyle = .thin
        delegate = self
        addArrangedSubview(settingsContent)
        settingsContent.clipsToBounds = true
        browserContent.clipsToBounds = true
        header.translatesAutoresizingMaskIntoConstraints = false
        viewport.translatesAutoresizingMaskIntoConstraints = false
        browserContent.addSubview(header)
        browserContent.addSubview(viewport)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: browserContent.topAnchor),
            header.leadingAnchor.constraint(equalTo: browserContent.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: browserContent.trailingAnchor),
            viewport.topAnchor.constraint(equalTo: header.bottomAnchor),
            viewport.leadingAnchor.constraint(equalTo: browserContent.leadingAnchor),
            viewport.trailingAnchor.constraint(equalTo: browserContent.trailingAnchor),
            viewport.bottomAnchor.constraint(equalTo: browserContent.bottomAnchor),
        ])
        viewport.clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func install(_ page: PageWebView) {
        settingsPage = page
        pin(page, to: settingsContent)
        page.onVisibilityChanged = { [weak self] visible in
            if !visible { self?.close(restoreFocus: false) }
        }
    }

    func openExternal(_ url: URL) {
        guard SettingsModelKeyPages.contains(url) else {
            LinkRouter.shared.open(url, in: .system)
            return
        }
        // task-owner: one browser open for the clicked key page.
        Task { [weak self] in
            guard let self, let window else { return }
            if !(await open(url, owner: "key:\(url.absoluteString)")), self.window === window {
                services.refusalHUD.show(RefusalStrings.chromiumUnavailable, in: window)
            }
        }
    }

    func open(_ url: URL, owner: String, on machine: DaemonService? = nil) async -> Bool {
        guard let window, !isHiddenOrHasHiddenAncestor, services.cache.browserTabs.cefUnavailable() == nil else { return false }
        let remote: (daemon: DaemonService, port: UInt16)?
        if let machine {
            guard let port = AgentPaneSignInPage.callbackPort(url),
                  ChatMachineSignInTab.isAvailable(on: machine, services: services) else { return false }
            remote = (machine, port)
        } else {
            remote = nil
        }
        if self.owner == owner, openingURL == url, currentTab != nil { return true }

        services.settingsWindow.claimSignInPane(self)
        let request = UUID()
        pending = request
        self.owner = owner
        openingURL = url
        closeTabs()
        header.showHost(url.host(percentEncoded: false) ?? "")
        self.remote = remote
        let profile = profile(in: window)
        // The Cloud approval starts in the person's profile with loopback blocked. Its callback
        // crosses into the machine's derived store only when Chromium asks the host to reroute.
        let config = BrowserTabConfiguration(profile: profile, navigationGuard: remote == nil ? .none : .noLoopback)
        guard let tab = try? await services.cache.cef.makeSignInTab(config) else {
            if pending == request { close(restoreFocus: false) }
            return false
        }
        guard pending == request, self.window === window, !isHiddenOrHasHiddenAncestor else {
            tab.close()
            if pending == request { close(restoreFocus: false) }
            return false
        }
        showSplit(in: window)
        tabs.append(tab)
        show(tab, startingAt: url)
        // Wait for Chromium to attach and install its navigation guard before the first load.
        guard await tab.agentRelay.browserCreated(), pending == request else {
            if pending == request { close(restoreFocus: false) }
            return false
        }
        tab.load(url)
        return true
    }

    func close(owner: String) {
        if self.owner == owner { close() }
    }

    func close(restoreFocus: Bool = true) {
        guard owner != nil else { return }
        let hadBrowser = browserContent.superview === self
        pending = UUID()
        owner = nil
        openingURL = nil
        remote = nil
        closeTabs()
        if hadBrowser {
            removeArrangedSubview(browserContent)
            browserContent.removeFromSuperview()
            adjustSubviews()
        }
        if let window = expandedWindow {
            if let originalMinimum { window.minSize = originalMinimum }
            if let originalFrame, !window.styleMask.contains(.fullScreen) {
                window.setFrame(originalFrame, display: true)
            }
        }
        expandedWindow = nil
        originalFrame = nil
        originalMinimum = nil
        if hadBrowser, restoreFocus { settingsPage?.focusPage() }
    }

    override func layout() {
        if let settingsPage { PageWebView.clipChromiumFrame(of: settingsPage, in: settingsContent) }
        super.layout()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window, window !== newWindow { close(restoreFocus: false) }
        super.viewWillMove(toWindow: newWindow)
    }

    private func profile(in window: NSWindow) -> BrowserProfileID {
        guard let controller = services.windows.owner(of: window) else {
            return services.browserProfiles.book.engineProfile(for: nil)
        }
        if services.windows.isIncognito(window: controller.state.id) {
            return services.windows.incognitoProfile()
        }
        let id = controller.focusedPane.flatMap { services.cache.browserTabs.resolveProfile($0.pane, nil) }
            ?? controller.state.roomBrowserProfileID
        return services.browserProfiles.book.engineProfile(for: id)
    }

    private func showSplit(in window: NSWindow) {
        guard browserContent.superview == nil else { return }
        let settingsWidth = bounds.width
        let frame = window.frame
        if let screen = window.screen, window.styleMask.contains(.resizable),
           !window.styleMask.contains(.fullScreen), !window.isZoomed {
            let visible = screen.visibleFrame
            let width = max(frame.width, min(frame.width + Self.defaultBrowserWidth + dividerThickness, visible.width))
            let left = max(visible.minX, min(frame.minX, visible.maxX - width))
            let expanded = NSRect(x: left, y: frame.minY, width: width, height: frame.height)
            expandedWindow = window
            originalFrame = frame
            originalMinimum = window.minSize
            window.setFrame(expanded, display: true)
            window.contentView?.layoutSubtreeIfNeeded()
            // Account for any sidebar or neighboring panes the workspace already shows.
            let available = bounds.width
            let needed = Self.minimumSettingsWidth + Self.minimumBrowserWidth + dividerThickness
            var minimum = window.minSize
            minimum.width = max(minimum.width, width - max(0, available - needed))
            window.minSize = minimum
        }
        addArrangedSubview(browserContent)
        setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        adjustSubviews()
        let preferred = min(settingsWidth, bounds.width - Self.defaultBrowserWidth - dividerThickness)
        setPosition(max(leftMinimum, min(preferred, rightLimit)), ofDividerAt: 0)
    }

    private var leftMinimum: CGFloat {
        min(Self.minimumSettingsWidth, max(0, bounds.width - browserMinimum - dividerThickness))
    }

    private var rightLimit: CGFloat {
        max(leftMinimum, bounds.width - browserMinimum - dividerThickness)
    }

    private var browserMinimum: CGFloat {
        min(Self.minimumBrowserWidth, max(0, (bounds.width - dividerThickness) * 0.45))
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, leftMinimum)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, rightLimit)
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        guard browserContent.superview === self else {
            settingsContent.frame = bounds
            return
        }
        let divider = max(leftMinimum, min(settingsContent.frame.width, rightLimit))
        settingsContent.frame = NSRect(x: 0, y: 0, width: divider, height: bounds.height)
        let browserStart = divider + dividerThickness
        browserContent.frame = NSRect(x: browserStart, y: 0, width: max(0, bounds.width - browserStart), height: bounds.height)
    }

    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect,
                   ofDividerAt dividerIndex: Int) -> NSRect {
        drawnRect.insetBy(dx: -4, dy: 0)
    }

    private func show(_ tab: any BrowserTab, startingAt url: URL?) {
        addressWatch?.cancel()
        viewport.subviews.first?.removeFromSuperview()
        tab.delegate = self
        tab.setContentVisible(true)
        pin(tab.contentView, to: viewport)
        header.showHost(url?.host(percentEncoded: false) ?? "")
        // task-owner: one address observation for the tab mounted in Settings.
        addressWatch = Task { [weak self, weak tab] in
            guard let tab else { return }
            for await address in ObservationStream({ tab.state.url }) {
                self?.header.showHost((address ?? url)?.host(percentEncoded: false) ?? "")
            }
        }
    }

    private func closeTabs() {
        redirectTask?.cancel()
        redirectTask = nil
        addressWatch?.cancel()
        addressWatch = nil
        for tab in tabs.reversed() {
            tab.delegate = nil
            tab.close()
        }
        tabs.removeAll()
    }

    func browserTab(_ tab: any BrowserTab, didRequest intent: BrowserTabIntent) {
        switch intent {
        case .adoptTab(let child, _), .openPopup(let child, _):
            // task-owner: attach this popup after Chromium's creation callback returns.
            Task { [weak self, weak tab] in
                guard let self, let tab, tab === currentTab else { return child.close() }
                tab.setContentVisible(false)
                tabs.append(child)
                show(child, startingAt: child.state.url)
                child.setFocused(true)
            }
        case .close:
            // task-owner: close the requested tab after Chromium's close callback returns.
            Task { [weak self, weak tab] in
                guard let self, let tab, tab === currentTab else { return }
                if tabs.count == 1 { close(); return }
                tabs.removeLast().close()
                if let previous = currentTab {
                    show(previous, startingAt: previous.state.url)
                    previous.setFocused(true)
                }
            }
        case .openURL(let url, _) where tab === currentTab:
            guard url.scheme == "https" || url.scheme == "http" else { return }
            // task-owner: start the new navigation after Chromium's current event returns.
            Task { [weak self, weak tab] in
                guard let tab, tab === self?.currentTab else { return }
                tab.load(url)
            }
        case .contextMenu(let request) where tab === currentTab:
            services.contextMenus.present(request, in: tab.contentView)
        case .rerouteStore(let url) where tab === currentTab:
            routeCallback(url, from: tab)
        default:
            break
        }
    }

    private func routeCallback(_ url: URL, from tab: any BrowserTab) {
        guard let remote, url.scheme == "http", url.host == "localhost", url.port == Int(remote.port),
              url.path == "/callback", url.user == nil, url.password == nil, redirectTask == nil else { return }
        let request = pending
        let base = BrowserTabConfiguration(profile: tab.profileID)
        // task-owner: forward this approval's single callback through the existing chat-machine store.
        redirectTask = Task { [weak self, weak tab] in
            guard let self else { return }
            defer { if pending == request { redirectTask = nil } }
            guard let configuration = await services.remoteLocalhost.chatMachineCallbackConfiguration(base, daemon: remote.daemon),
                  let callback = try? await services.cache.cef.makeSignInTab(configuration) else {
                if pending == request {
                    services.refusalHUD.show(RefusalStrings.chromiumUnavailable, in: window)
                }
                return
            }
            guard pending == request, !Task.isCancelled, let tab, tab === currentTab else { return callback.close() }
            tabs.removeLast().close()
            tabs.append(callback)
            show(callback, startingAt: url)
            guard await callback.agentRelay.browserCreated(), pending == request, callback === currentTab else { return }
            callback.load(url)
        }
    }

    private func pin(_ child: NSView, to parent: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
    }
}
