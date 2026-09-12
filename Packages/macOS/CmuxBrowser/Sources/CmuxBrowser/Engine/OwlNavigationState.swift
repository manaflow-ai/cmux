import Foundation

/// The numeric mouse kinds declared by the OWL `OwlFreshMouseKind` Mojo enum.
/// Keep these values in one place because the C ABI accepts the enum as a raw
/// integer and silently accepts an incorrect value.
enum OwlFreshMouseKind: UInt32, Equatable, Sendable {
    case down = 0
    case up = 1
    case move = 2
    case wheel = 3

    init(cdpType: String) {
        switch cdpType {
        case "mousePressed": self = .down
        case "mouseReleased": self = .up
        case "mouseWheel": self = .wheel
        default: self = .move
        }
    }
}

/// A pending native navigation and the URL it should commit, when known.
enum OwlNavigationIntent: Equatable, Sendable {
    case destination(URL)
    case rendererDestination(URL)
    case back(URL)
    case forward(URL)
    case reload(URL?)

    var expectedURL: URL? {
        switch self {
        case .destination(let url), .rendererDestination(let url), .back(let url), .forward(let url): return url
        case .reload(let url): return url
        }
    }
}

/// The small amount of history state OWL exposes without CDP's navigation
/// history domain. It is intentionally value typed so its no-op behavior can
/// be covered without launching Content Shell.
struct OwlNavigationHistoryState: Equatable, Sendable {
    private(set) var entries: [URL]
    private(set) var currentIndex: Int

    init(initialURL: URL?) {
        if let initialURL {
            entries = [initialURL]
            currentIndex = 0
        } else {
            entries = []
            currentIndex = 0
        }
    }

    var canGoBack: Bool { currentIndex > entries.startIndex }
    var canGoForward: Bool {
        !entries.isEmpty && currentIndex < entries.index(before: entries.endIndex)
    }

    var backURLs: [URL] {
        guard !entries.isEmpty else { return [] }
        return Array(entries[..<currentIndex])
    }

    var forwardURLs: [URL] {
        guard currentIndex + 1 < entries.endIndex else { return [] }
        return Array(entries[(currentIndex + 1)...])
    }

    func targetURL(offset: Int) -> URL? {
        let targetIndex = currentIndex + offset
        guard entries.indices.contains(targetIndex) else { return nil }
        return entries[targetIndex]
    }

    mutating func commitDestination(_ url: URL) {
        if entries.isEmpty {
            entries = [url]
            currentIndex = 0
            return
        }
        entries.removeSubrange((currentIndex + 1)..<entries.endIndex)
        entries.append(url)
        currentIndex = entries.index(before: entries.endIndex)
    }

    mutating func commitTraversal(to url: URL) {
        guard let index = entries.firstIndex(of: url) else {
            commitDestination(url)
            return
        }
        currentIndex = index
    }

    mutating func commitTraversal(to url: URL, offset: Int) {
        let targetIndex = currentIndex + offset
        guard entries.indices.contains(targetIndex),
              Self.matches(entries[targetIndex], url) else {
            return
        }
        currentIndex = targetIndex
    }

    private static func matches(_ lhs: URL, _ rhs: URL) -> Bool {
        if lhs.absoluteString == rhs.absoluteString { return true }
        guard lhs.scheme?.caseInsensitiveCompare(rhs.scheme ?? "") == .orderedSame,
              lhs.host?.caseInsensitiveCompare(rhs.host ?? "") == .orderedSame,
              effectivePort(for: lhs) == effectivePort(for: rhs),
              lhs.user == rhs.user,
              lhs.password == rhs.password,
              navigationPath(for: lhs) == navigationPath(for: rhs),
              lhs.query == rhs.query,
              lhs.fragment == rhs.fragment else {
            return false
        }
        return true
    }

    private static func navigationPath(for url: URL) -> String {
        guard !url.path.isEmpty else {
            switch url.scheme?.lowercased() {
            case "http", "https": return "/"
            default: return url.path
            }
        }
        return url.path
    }

    private static func effectivePort(for url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    mutating func commitReload() {
        // A reload keeps the current history entry and only changes readiness.
    }
}

/// OWL page-state callbacks may include title-only updates. A terminal event
/// is valid only after the current operation has observed its loading edge;
/// this prevents a stale `loading == false` title update from completing a
/// newer navigation.
enum OwlNavigationCompletionPredicate {
    static func accepts(
        loading: Bool,
        sawLoadingEvent: Bool,
        targetMatches: Bool
    ) -> Bool {
        !loading && sawLoadingEvent && targetMatches
    }

    static func readinessAccepts(
        sawLoadingEvent: Bool,
        targetMatches: Bool,
        readyState: String,
        documentEpochAdvanced: Bool,
        requiresReloadNavigation: Bool,
        navigationType: String
    ) -> Bool {
        sawLoadingEvent &&
            targetMatches &&
            readyState == "complete" &&
            documentEpochAdvanced &&
            (!requiresReloadNavigation || navigationType == "reload")
    }
}
