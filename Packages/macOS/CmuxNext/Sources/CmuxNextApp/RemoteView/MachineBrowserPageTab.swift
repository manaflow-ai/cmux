import AppKit
import CmuxNextBrowser
import CmuxNextBrowserTabs
import CmuxNextDesign
import CmuxNextIcons
import Foundation
import Observation

/// The page of a `MachineBrowserRecord` tab while the machine's browser is
/// not ready (cx-2cob slice 1): why, the address the person typed (it
/// waits) and Open Locally Instead (slice 1a); no Retry: it checks again by itself while shown (``AutoRetry``).
@MainActor
@Observable
final class MachineBrowserPageTab: BrowserTab {
    let id: BrowserTabID
    let engineKind: BrowserEngineKind
    let profileID: BrowserProfileID
    let presentation: BrowserPresentation = .inView
    private(set) var state: BrowserTabState
    let favicon: NSImage? = NSImage.icon(.tabBrowser, size: 16)
    let pendingPrompts: [BrowserPrompt] = []
    @ObservationIgnored weak var delegate: (any BrowserTabDelegate)?
    @ObservationIgnored weak var keyRouter: (any BrowserKeyRouting)?
    @ObservationIgnored let record: MachineBrowserRecord
    @ObservationIgnored private let view: MachineBrowserStateView
    @ObservationIgnored private let currentState: @MainActor () -> MachineBrowserState
    @ObservationIgnored private let openLocallyHandler: @MainActor (URL?) -> Void
    /// Starts the machine's browser (each check, and once at creation); unset: a check only rereads the state.
    @ObservationIgnored var onStart: (@MainActor () -> Void)?
    /// A start in progress or its failure, over the machine's state.
    @ObservationIgnored var phase: MachineBrowserState? {
        didSet { settle() }
    }
    @ObservationIgnored private let retry = AutoRetry(owner: "machineBrowserPage")
    /// The address the person typed (or the record's first page): it opens
    /// when the machine's browser is ready, or here with Open Locally Instead.
    private(set) var queuedURL: URL?

    var contentView: NSView { view }
    /// The message shown (debug socket).
    var messageText: String { view.messageText }

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
        retry.setAttempt { [weak self] in self?.reload() }
        settle()
    }

    private var isStarting: Bool {
        guard case .starting = phase else { return false }
        return true
    }

    /// Open Locally Instead (the button, `browser.openLocally`).
    func openLocally() { openLocallyHandler(queuedURL) }

    /// The omnibar: a web address waits for the machine's browser.
    func load(_ url: URL) {
        guard !MachineBrowserRecord.matches(url) else { return reload() }
        queuedURL = url
        state.url = url
        draw()
    }

    /// Reload and each automatic check: checks the machine again and starts its browser when it can.
    func reload() {
        if let onStart, !isStarting { onStart() } else { settle() }
    }
    /// Shows the state and arms the next check while not ready and shown (``retry``).
    private func settle() {
        switch phase ?? currentState() {
        case .ready: retry.succeeded()
        case .starting: break
        case .unavailable: retry.stop() // for good
        case .notConnected, .notInstalled, .tooOld, .failed: retry.failed()
        }
        draw()
    }
    /// A failed start reads as starting until the quiet bound.
    private func draw() {
        let shown = phase ?? currentState()
        if case let .failed(name, _) = shown, !retry.showsNotice { return view.show(.starting(name), queued: queuedURL) }
        view.show(shown, queued: queuedURL)
    }
    func goBack() {}
    func goForward() {}
    func stop() {}

    func setFocused(_ focused: Bool) {
        guard focused, let window = contentView.window else { return }
        window.makeFirstResponder(view.openLocallyButton)
    }

    func setContentVisible(_ visible: Bool) {
        contentView.isHidden = !visible
        if visible { draw() }
        retry.setInSight(visible)
    }

    func snapshot() async throws -> CGImage {
        guard let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else { throw BrowserTabError.snapshotUnavailable }
        contentView.cacheDisplay(in: contentView.bounds, to: rep)
        guard let image = rep.cgImage else { throw BrowserTabError.snapshotUnavailable }
        return image
    }

    func evaluate(_ script: String, world: BrowserScriptWorld, gesture: BrowserScriptGesture) async throws -> BrowserJSValue { throw BrowserTabError.unsupported("machine browser") }
    func find(_ text: String, direction: BrowserFindDirection, caseSensitive: Bool) async -> BrowserFindResult { .none }
    func clearFind() {}
    func setZoom(_ zoom: Double) {}
    func exitContentFullscreen() {}
    func showDevTools() {}
    func close() { retry.stop() }
}

/// The not-ready message, the waiting address and Open Locally Instead.
final class MachineBrowserStateView: NSView {
    private let message = ThemedLabel(wrappingLabelWithString: "")
    private let queued = ThemedLabel(wrappingLabelWithString: "")
    let openLocallyButton = ThemedDefaultButton(title: MachineBrowserStrings.openLocally, target: nil, action: nil)
    var onOpenLocally: (() -> Void)?
    /// The message shown (tests, debug).
    var messageText: String { message.stringValue }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for label in [message, queued] {
            label.alignment = .center
            label.isSelectable = true
            label.focusRingType = .none
        }
        message.font = .systemFont(ofSize: NSFont.systemFontSize + 1, weight: .medium)
        queued.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        queued.ink = .secondary
        openLocallyButton.target = self
        openLocallyButton.action = #selector(openLocallyPressed)
        openLocallyButton.keyHint = .return
        let stack = NSStackView(views: [message, queued, openLocallyButton])
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
}

/// Strings of machine browser tabs (Resources/Remote.xcstrings).
nonisolated enum MachineBrowserStrings {
    static var notReadyTitle: String {
        String(localized: "remote.machineBrowser.notReady", defaultValue: "Not Ready", table: "Remote", bundle: .module.inAppLanguage)
    }
    static func notInstalled(_ machine: String) -> String {
        String(format: String(localized: "remote.machineBrowser.notInstalled",
                              defaultValue: "The browser is not installed on %@ yet, so this tab cannot run there.",
                              table: "Remote", bundle: .module.inAppLanguage), machine)
    }
    static func unavailable(_ machine: String) -> String {
        String(format: String(localized: "remote.machineBrowser.unavailable",
                              defaultValue: "Browser tabs that run on %@ are not available yet.", table: "Remote", bundle: .module.inAppLanguage), machine)
    }
    static func notConnected(_ machine: String) -> String {
        String(format: String(localized: "remote.machineBrowser.notConnected",
                              defaultValue: "%@ is not connected.", table: "Remote", bundle: .module.inAppLanguage), machine)
    }
    static func tooOld(_ machine: String) -> String {
        String(format: String(localized: "remote.machineBrowser.tooOld",
                              defaultValue: "cmux on %@ is too old for browser tabs. Once it is updated there, this tab opens.",
                              table: "Remote", bundle: .module.inAppLanguage), machine)
    }
    static func starting(_ machine: String) -> String {
        String(format: String(localized: "remote.machineBrowser.starting",
                              defaultValue: "Starting the browser on %@…", table: "Remote", bundle: .module.inAppLanguage), machine)
    }
    static func failed(_ machine: String, _ reason: String) -> String {
        String(format: String(localized: "remote.machineBrowser.failed",
                              defaultValue: "The browser on %1$@ did not start: %2$@", table: "Remote", bundle: .module.inAppLanguage), machine, reason)
    }
    static func waiting(_ address: String) -> String {
        String(format: String(localized: "remote.machineBrowser.waiting",
                              defaultValue: "%@ opens when the browser is ready.", table: "Remote", bundle: .module.inAppLanguage), address)
    }
    static var openLocally: String {
        String(localized: "remote.machineBrowser.openLocally", defaultValue: "Open Locally Instead", table: "Remote", bundle: .module.inAppLanguage)
    }
    /// The omnibar chip of a tab of another machine that runs on this Mac.
    static var thisMac: String {
        String(localized: "remote.machineBrowser.thisMac", defaultValue: "This Mac", table: "Remote", bundle: .module.inAppLanguage)
    }
    /// The This Mac chip's menu item.
    static func openOn(_ machine: String) -> String {
        String(format: String(localized: "remote.machineBrowser.openOn", defaultValue: "Open on %@", table: "Remote", bundle: .module.inAppLanguage), machine)
    }
}
