public import Foundation

/// A browser engine. One instance per engine kind per process.
///
/// `makeTab` is async because CEF initializes lazily on its first tab.
public protocol BrowserEngine: AnyObject, Sendable {
    var kind: BrowserEngineKind { get }
    var availability: BrowserEngineAvailability { get }
    var capabilities: BrowserCapabilities { get }
    func makeTab(_ configuration: BrowserTabConfiguration) async throws -> any BrowserTab
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
