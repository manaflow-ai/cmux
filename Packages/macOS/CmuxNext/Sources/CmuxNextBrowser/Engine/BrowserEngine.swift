public import AppKit
public import Foundation
public import Observation

/// Features an engine supports. Callers branch on capabilities, never on
/// engine kind (plans/cmux-next/browser.md section 3).
public nonisolated struct BrowserCapabilities: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Chrome DevTools Protocol access to the tab.
    public static let cdp = BrowserCapabilities(rawValue: 1 << 0)
    /// Real Chrome extensions.
    public static let extensions = BrowserCapabilities(rawValue: 1 << 1)
    /// Trusted (non-synthetic) input events for automation.
    public static let trustedInput = BrowserCapabilities(rawValue: 1 << 2)
    /// Request interception.
    public static let networkIntercept = BrowserCapabilities(rawValue: 1 << 3)
    /// Script access to cross-origin frames.
    public static let crossOriginFrames = BrowserCapabilities(rawValue: 1 << 4)
    /// A developer tools inspector.
    public static let devTools = BrowserCapabilities(rawValue: 1 << 5)
    /// Downloads reported through `BrowserTabIntent.download`.
    public static let downloads = BrowserCapabilities(rawValue: 1 << 6)
    /// Element fullscreen stays inside the pane.
    public static let paneFullscreen = BrowserCapabilities(rawValue: 1 << 7)
    /// `snapshot()` returns page pixels.
    public static let snapshots = BrowserCapabilities(rawValue: 1 << 8)
    /// `find` reports a match count.
    public static let findMatchCount = BrowserCapabilities(rawValue: 1 << 9)
}

/// Whether an engine can create tabs in this process.
public nonisolated enum BrowserEngineAvailability: Hashable, Sendable {
    case available
    /// The engine cannot run; `reason` is a localized user-facing sentence.
    case unavailable(reason: String)

    public var isAvailable: Bool { self == .available }
}

public nonisolated enum BrowserEngineError: Error, Hashable, Sendable {
    case engineNotRegistered(BrowserEngineKind)
    case engineUnavailable(BrowserEngineKind, reason: String)
}

/// Everything needed to create a tab.
public nonisolated struct BrowserTabConfiguration: Hashable, Sendable {
    public var id: BrowserTabID
    public var profile: BrowserProfileID
    /// Loaded right after creation. nil leaves the tab blank.
    public var initialURL: URL?
    /// Starting zoom, e.g. a per-site zoom the App layer remembers.
    public var zoom: Double

    public init(
        id: BrowserTabID = .random(),
        profile: BrowserProfileID = .default,
        initialURL: URL? = nil,
        zoom: Double = 1
    ) {
        self.id = id
        self.profile = profile
        self.initialURL = initialURL
        self.zoom = zoom
    }
}

/// A browser engine. One instance per engine kind per process.
///
/// `makeTab` is async because CEF initializes lazily on its first tab.
public protocol BrowserEngine: AnyObject, Sendable {
    var kind: BrowserEngineKind { get }
    var availability: BrowserEngineAvailability { get }
    var capabilities: BrowserCapabilities { get }
    func makeTab(_ configuration: BrowserTabConfiguration) async throws -> any BrowserTab
}

/// One live page. Engine-neutral: the chrome, the App layer, and automation
/// talk only to this protocol.
///
/// Conforming types are `@Observable`, so `state`, `favicon`, and
/// `pendingPrompts` can be tracked with Observation.
public protocol BrowserTab: AnyObject, Observable, Sendable {
    var id: BrowserTabID { get }
    var engineKind: BrowserEngineKind { get }
    var profileID: BrowserProfileID { get }
    var presentation: BrowserPresentation { get }

    /// The view to place in the pane. For `.childWindow` engines this is the
    /// placeholder the child window tracks.
    var contentView: NSView { get }

    var state: BrowserTabState { get }
    var favicon: NSImage? { get }
    /// Unanswered permission requests and JavaScript dialogs, oldest first.
    var pendingPrompts: [BrowserPrompt] { get }

    var delegate: (any BrowserTabDelegate)? { get set }
    var keyRouter: (any BrowserKeyRouting)? { get set }

    func load(_ url: URL)
    func goBack()
    func goForward()
    func reload()
    func stop()

    /// Gives or removes keyboard focus from the page.
    func setFocused(_ focused: Bool)
    /// Called around animations and when the tab is hidden. `.childWindow`
    /// engines swap in a snapshot; `.inView` engines may throttle.
    func setOccluded(_ occluded: Bool) async

    /// Page pixels for hover previews and occlusion placeholders.
    func snapshot() async throws -> CGImage

    /// Evaluates a script and returns its completion value.
    func evaluate(_ script: String, world: BrowserScriptWorld) async throws -> BrowserJSValue

    /// Highlights the next or previous match of `text`.
    func find(_ text: String, direction: BrowserFindDirection, caseSensitive: Bool) async -> BrowserFindResult
    func clearFind()

    func setZoom(_ zoom: Double)

    /// Leaves in-pane content fullscreen, if active.
    func exitContentFullscreen()

    func showDevTools()

    /// Tears the page down. Pending prompts are dismissed. Idempotent.
    func close()
}

extension BrowserTab {
    public func zoomIn() { setZoom(BrowserZoom.zoomIn(from: state.zoom)) }
    public func zoomOut() { setZoom(BrowserZoom.zoomOut(from: state.zoom)) }
    public func resetZoom() { setZoom(1) }

    public func evaluate(_ script: String) async throws -> BrowserJSValue {
        try await evaluate(script, world: .page)
    }
}

/// Holds one engine per kind and creates tabs through them.
public final class BrowserEngineRegistry {
    private var engines: [BrowserEngineKind: any BrowserEngine] = [:]

    public init(engines: [any BrowserEngine] = []) {
        for engine in engines { register(engine) }
    }

    public func register(_ engine: any BrowserEngine) {
        engines[engine.kind] = engine
    }

    public func engine(for kind: BrowserEngineKind) -> (any BrowserEngine)? {
        engines[kind]
    }

    /// Kinds that can create tabs now, in declaration order.
    public var availableKinds: [BrowserEngineKind] {
        BrowserEngineKind.allCases.filter { engines[$0]?.availability.isAvailable == true }
    }

    public func makeTab(kind: BrowserEngineKind, _ configuration: BrowserTabConfiguration) async throws -> any BrowserTab {
        guard let engine = engines[kind] else {
            throw BrowserEngineError.engineNotRegistered(kind)
        }
        if case .unavailable(let reason) = engine.availability {
            throw BrowserEngineError.engineUnavailable(kind, reason: reason)
        }
        return try await engine.makeTab(configuration)
    }
}
