public import AppKit
import CmuxNextDesign
public import Foundation
public import Observation

/// An in-memory engine for demos, previews, and tests of code that consumes
/// `BrowserTab`. It keeps its own back/forward list and feeds the same
/// `BrowserTabStateMachine` real engines use.
public final class MockBrowserEngine: BrowserEngine {
    public let kind: BrowserEngineKind
    public var availability: BrowserEngineAvailability = .available
    public var capabilities: BrowserCapabilities = [.snapshots, .findMatchCount]

    /// When true, `load` completes synchronously (start, commit, finish).
    public var completesNavigationsImmediately: Bool

    /// Every tab this engine created, in order.
    public private(set) var tabs: [MockBrowserTab] = []

    public init(kind: BrowserEngineKind = .webkit, completesNavigationsImmediately: Bool = true) {
        self.kind = kind
        self.completesNavigationsImmediately = completesNavigationsImmediately
    }

    public func makeTab(_ configuration: BrowserTabConfiguration) async throws -> any BrowserTab {
        makeMockTab(configuration)
    }

    public func makeMockTab(_ configuration: BrowserTabConfiguration) -> MockBrowserTab {
        let tab = MockBrowserTab(
            configuration: configuration,
            engineKind: kind,
            completesNavigationsImmediately: completesNavigationsImmediately
        )
        tabs.append(tab)
        if let url = configuration.initialURL {
            tab.load(url)
        }
        return tab
    }
}

/// A fake page. Commands are recorded; navigation events can be driven by
/// hand with `simulate` to reproduce engine callback orders.
@Observable
public final class MockBrowserTab: BrowserTab {
    public enum Command: Hashable, Sendable {
        case load(URL)
        case goBack
        case goForward
        case reload
        case stop
        case setZoom(Double)
        case find(String, BrowserFindDirection)
        case clearFind
        case evaluate(String)
        case focus(Bool)
        case occlude(Bool)
        case exitContentFullscreen
        case showDevTools
        case close
    }

    public let id: BrowserTabID
    public let engineKind: BrowserEngineKind
    public let profileID: BrowserProfileID
    public let presentation: BrowserPresentation = .inView
    public var completesNavigationsImmediately: Bool

    public var state: BrowserTabState { machine.state }
    public var favicon: NSImage?
    public private(set) var pendingPrompts: [BrowserPrompt] = []
    public private(set) var commands: [Command] = []
    public private(set) var isClosed = false

    /// Page text used by `find`.
    public var pageText = ""
    /// Canned result for `evaluate`.
    public var evaluationResult: BrowserJSValue = .null

    @ObservationIgnored public weak var delegate: (any BrowserTabDelegate)?
    @ObservationIgnored public weak var keyRouter: (any BrowserKeyRouting)?
    /// Page Info fakes (`MockBrowserTab+PageInfo`).
    @ObservationIgnored public let pageInfoActivity = PageInfoActivity()
    @ObservationIgnored public var pageInfoFake = MockPageInfoData()

    private var machine = BrowserTabStateMachine()
    /// The current back/forward list entry. Updated when a navigation
    /// starts, which is enough for a fake.
    private var committedURL: URL?
    private var backList: [URL] = []
    private var forwardList: [URL] = []
    private var nextNavigation: UInt64 = 0
    @ObservationIgnored private lazy var placeholder = MockPageView()

    init(configuration: BrowserTabConfiguration, engineKind: BrowserEngineKind, completesNavigationsImmediately: Bool) {
        self.id = configuration.id
        self.engineKind = engineKind
        self.profileID = configuration.profile
        self.completesNavigationsImmediately = completesNavigationsImmediately
        machine.apply(.zoomChanged(configuration.zoom))
    }

    public var contentView: NSView {
        placeholder.text = state.title ?? state.url?.absoluteString ?? ""
        return placeholder
    }

    // MARK: Driving

    /// Feeds one engine event into the state machine.
    public func simulate(_ event: BrowserNavigationEvent) {
        machine.apply(event)
    }

    /// Allocates the id a real engine would assign to a new navigation.
    public func makeNavigationID() -> BrowserNavigationID {
        nextNavigation += 1
        return BrowserNavigationID(rawValue: nextNavigation)
    }

    /// Queues a prompt as if the page asked for it.
    @discardableResult
    public func presentPrompt(_ kind: BrowserPromptKind, origin: String) async -> BrowserPromptResponse {
        await withCheckedContinuation { continuation in
            var prompt: BrowserPrompt!
            prompt = BrowserPrompt(kind: kind, origin: origin) { [weak self] response in
                self?.pendingPrompts.removeAll { $0 === prompt }
                continuation.resume(returning: response)
            }
            pendingPrompts.append(prompt)
        }
    }

    public func emit(_ intent: BrowserTabIntent) {
        delegate?.browserTab(self, didRequest: intent)
    }

    // MARK: BrowserTab

    public func load(_ url: URL) {
        commands.append(.load(url))
        if let current = committedURL {
            backList.append(current)
        }
        forwardList.removeAll()
        navigate(to: url)
    }

    public func goBack() {
        commands.append(.goBack)
        guard let target = backList.popLast() else { return }
        if let current = committedURL { forwardList.append(current) }
        navigate(to: target)
    }

    public func goForward() {
        commands.append(.goForward)
        guard let target = forwardList.popLast() else { return }
        if let current = committedURL { backList.append(current) }
        navigate(to: target)
    }

    public func reload() {
        commands.append(.reload)
        guard let url = committedURL else { return }
        navigate(to: url)
    }

    public func stop() {
        commands.append(.stop)
        machine.apply(.stopped)
    }

    public func setFocused(_ focused: Bool) { commands.append(.focus(focused)) }

    public func setOccluded(_ occluded: Bool) async { commands.append(.occlude(occluded)) }

    public func snapshot() async throws -> CGImage {
        guard !isClosed else { throw BrowserTabError.closed }
        let size = 4
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.setFillColor(gray: 0.5, alpha: 1)
        context?.fill(CGRect(x: 0, y: 0, width: size, height: size))
        guard let image = context?.makeImage() else { throw BrowserTabError.snapshotUnavailable }
        return image
    }

    public func evaluate(_ script: String, world: BrowserScriptWorld) async throws -> BrowserJSValue {
        guard !isClosed else { throw BrowserTabError.closed }
        commands.append(.evaluate(script))
        return evaluationResult
    }

    public func find(_ text: String, direction: BrowserFindDirection, caseSensitive: Bool) async -> BrowserFindResult {
        commands.append(.find(text, direction))
        guard !text.isEmpty else { return .none }
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var count = 0
        var range = pageText.startIndex..<pageText.endIndex
        while let found = pageText.range(of: text, options: options, range: range) {
            count += 1
            range = found.upperBound..<pageText.endIndex
        }
        return BrowserFindResult(matchFound: count > 0, matchCount: count)
    }

    public func clearFind() { commands.append(.clearFind) }

    public func setZoom(_ zoom: Double) {
        commands.append(.setZoom(zoom))
        machine.apply(.zoomChanged(zoom))
    }

    public func exitContentFullscreen() {
        commands.append(.exitContentFullscreen)
        machine.apply(.contentFullscreenChanged(false))
    }

    public func showDevTools() { commands.append(.showDevTools) }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        commands.append(.close)
        for prompt in pendingPrompts { prompt.respond(prompt.dismissalResponse) }
        pendingPrompts.removeAll()
    }

    // MARK: Private

    private func navigate(to url: URL) {
        let navigation = makeNavigationID()
        committedURL = url
        machine.apply(.started(navigation, url: url))
        machine.apply(.historyChanged(canGoBack: !backList.isEmpty, canGoForward: !forwardList.isEmpty))
        guard completesNavigationsImmediately else { return }
        machine.apply(.committed(navigation, url: url))
        machine.apply(.titleChanged(url.host() ?? url.absoluteString))
        machine.apply(.progress(1))
        machine.apply(.finished(navigation))
    }
}

/// Gray placeholder that shows the mock page's title.
final class MockPageView: NSView {
    private let label = NSTextField(labelWithString: "")

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Palette.hoverFill.cgColor
        label.textColor = Palette.textSecondary
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
