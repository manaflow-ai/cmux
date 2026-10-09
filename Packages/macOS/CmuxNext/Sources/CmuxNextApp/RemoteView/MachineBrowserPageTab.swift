import AppKit
import CmuxNextBrowser
import Foundation
import Observation

/// The page of a `MachineBrowserRecord` tab while the machine's browser is
/// not ready (cx-2cob slice 1): why, the address the person typed (it
/// waits), Open Locally Instead (this Mac's tab at that address, slice 1a)
/// and Retry. A native view, no engine, like `RemoteViewPageTab`.
@MainActor
@Observable
final class MachineBrowserPageTab: BrowserTab {
    let id: BrowserTabID
    let engineKind: BrowserEngineKind
    let profileID: BrowserProfileID
    let presentation: BrowserPresentation = .inView
    private(set) var state: BrowserTabState
    let favicon: NSImage? = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
    let pendingPrompts: [BrowserPrompt] = []
    @ObservationIgnored weak var delegate: (any BrowserTabDelegate)?
    @ObservationIgnored weak var keyRouter: (any BrowserKeyRouting)?
    @ObservationIgnored let record: MachineBrowserRecord
    @ObservationIgnored private let view: MachineBrowserStateView
    @ObservationIgnored private let currentState: @MainActor () -> MachineBrowserState
    @ObservationIgnored private let openLocallyHandler: @MainActor (URL?) -> Void
    /// The address the person typed (or the record's first page): it opens
    /// when the machine's browser is ready, or here with Open Locally Instead.
    private(set) var queuedURL: URL?

    var contentView: NSView { view }

    init(id: BrowserTabID, engine: BrowserEngineKind, profile: BrowserProfileID, record: MachineBrowserRecord,
         state: @escaping @MainActor () -> MachineBrowserState, openLocally: @escaping @MainActor (URL?) -> Void) {
        self.id = id
        engineKind = engine
        profileID = profile
        self.record = record
        currentState = state
        openLocallyHandler = openLocally
        queuedURL = record.initialURL
        var tabState = BrowserTabState(url: record.initialURL, title: MachineBrowserStrings.notReadyTitle)
        tabState.phase = .finished
        self.state = tabState
        view = MachineBrowserStateView()
        view.onOpenLocally = { [weak self] in self?.openLocally() }
        view.onRetry = { [weak self] in self?.reload() }
        view.show(state(), queued: record.initialURL)
    }

    /// Open Locally Instead (the button, `browser.openLocally`).
    func openLocally() { openLocallyHandler(queuedURL) }

    /// The omnibar: a web address waits for the machine's browser.
    func load(_ url: URL) {
        guard !MachineBrowserRecord.matches(url) else { return reload() }
        queuedURL = url
        state.url = url
        view.show(currentState(), queued: url)
    }

    /// Retry: checks the machine again.
    func reload() { view.show(currentState(), queued: queuedURL) }
    func goBack() {}
    func goForward() {}
    func stop() {}

    func setFocused(_ focused: Bool) {
        guard focused, let window = contentView.window else { return }
        window.makeFirstResponder(view.openLocallyButton)
    }

    func setContentVisible(_ visible: Bool) {
        contentView.isHidden = !visible
        if visible { reload() }
    }

    func snapshot() async throws -> CGImage {
        guard let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else { throw BrowserTabError.snapshotUnavailable }
        contentView.cacheDisplay(in: contentView.bounds, to: rep)
        guard let image = rep.cgImage else { throw BrowserTabError.snapshotUnavailable }
        return image
    }

    func evaluate(_ script: String, world: BrowserScriptWorld) async throws -> BrowserJSValue { throw BrowserTabError.unsupported("machine browser") }
    func find(_ text: String, direction: BrowserFindDirection, caseSensitive: Bool) async -> BrowserFindResult { .none }
    func clearFind() {}
    func setZoom(_ zoom: Double) {}
    func exitContentFullscreen() {}
    func showDevTools() {}
    func close() {}
}

/// The not-ready message, the waiting address and the two buttons.
final class MachineBrowserStateView: NSView {
    private let message = NSTextField(wrappingLabelWithString: "")
    private let queued = NSTextField(wrappingLabelWithString: "")
    let openLocallyButton = NSButton(title: MachineBrowserStrings.openLocally, target: nil, action: nil)
    private let retryButton = NSButton(title: MachineBrowserStrings.retry, target: nil, action: nil)
    var onOpenLocally: (() -> Void)?
    var onRetry: (() -> Void)?
    /// The message shown (tests, debug).
    var messageText: String { message.stringValue }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for label in [message, queued] {
            label.alignment = .center
            label.isSelectable = true
        }
        message.font = .systemFont(ofSize: NSFont.systemFontSize + 1, weight: .medium)
        queued.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        queued.textColor = .secondaryLabelColor
        openLocallyButton.target = self
        openLocallyButton.action = #selector(openLocallyPressed)
        openLocallyButton.keyEquivalent = "\r"
        retryButton.target = self
        retryButton.action = #selector(retryPressed)
        let buttons = NSStackView(views: [retryButton, openLocallyButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [message, queued, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ state: MachineBrowserState, queued url: URL?) {
        message.stringValue = state.message
        queued.stringValue = url.map { MachineBrowserStrings.waiting($0.host() ?? $0.absoluteString) } ?? ""
        queued.isHidden = url == nil
    }

    @objc private func openLocallyPressed() { onOpenLocally?() }
    @objc private func retryPressed() { onRetry?() }
}

/// Strings of machine browser tabs (Resources/Remote.xcstrings).
nonisolated enum MachineBrowserStrings {
    static var notReadyTitle: String {
        String(localized: "remote.machineBrowser.notReady", defaultValue: "Not Ready", table: "Remote", bundle: .module)
    }
    static func notInstalled(_ machine: String) -> String {
        String(format: String(localized: "remote.machineBrowser.notInstalled",
                              defaultValue: "The browser is not installed on %@ yet, so this tab cannot run there.",
                              table: "Remote", bundle: .module), machine)
    }
    static func unavailable(_ machine: String) -> String {
        String(format: String(localized: "remote.machineBrowser.unavailable",
                              defaultValue: "Browser tabs that run on %@ are not available yet.", table: "Remote", bundle: .module), machine)
    }
    static func notConnected(_ machine: String) -> String {
        String(format: String(localized: "remote.machineBrowser.notConnected",
                              defaultValue: "%@ is not connected.", table: "Remote", bundle: .module), machine)
    }
    static func waiting(_ address: String) -> String {
        String(format: String(localized: "remote.machineBrowser.waiting",
                              defaultValue: "%@ opens when the browser is ready.", table: "Remote", bundle: .module), address)
    }
    static var openLocally: String {
        String(localized: "remote.machineBrowser.openLocally", defaultValue: "Open Locally Instead", table: "Remote", bundle: .module)
    }
    /// The omnibar chip of a tab of another machine that runs on this Mac.
    static var thisMac: String {
        String(localized: "remote.machineBrowser.thisMac", defaultValue: "This Mac", table: "Remote", bundle: .module)
    }
    static var retry: String {
        String(localized: "remote.machineBrowser.retry", defaultValue: "Retry", table: "Remote", bundle: .module)
    }
}
