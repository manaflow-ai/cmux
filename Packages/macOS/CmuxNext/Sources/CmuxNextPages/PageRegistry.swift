import AppKit

/// The live page views, for the generic page debug verb and the key dispatcher's lookups.
@MainActor
public struct PageRegistry {
    public init() {}
    private static let views = NSHashTable<PageWebView>.weakObjects()
    /// Creation order of the live views (``instance(of:)``).
    private static var serials: [ObjectIdentifier: UInt64] = [:]
    private static var nextSerial: UInt64 = 0

    static func add(_ view: PageWebView) {
        views.add(view)
        nextSerial += 1
        serials[ObjectIdentifier(view)] = nextSerial
        if serials.count > 2 * views.count + 16 {
            let live = Set(views.allObjects.map(ObjectIdentifier.init))
            serials = serials.filter { live.contains($0.key) }
        }
    }

    /// A stable number for a live view, in creation order (the `instance` of `debug.page`).
    public static func instance(of view: PageWebView) -> UInt64 {
        serials[ObjectIdentifier(view)] ?? 0
    }

    /// Live views of page `id` (every page when nil), oldest first.
    public static func pages(id: String? = nil) -> [PageWebView] {
        views.allObjects.filter { id == nil || $0.pageID == id }.sorted { instance(of: $0) < instance(of: $1) }
    }

    /// The page a probe means: `instance` when given; else a page that is not the parked spare (the
    /// spare when `parked`), the one in the key window first, else the newest. The parked spare runs
    /// its document with no routes, so a probe that read it reported state no visible page showed.
    public static func probeTarget(id: String?, parked: Bool = false, instance: UInt64? = nil) -> PageWebView? {
        let live = pages(id: id)
        if let instance { return live.first { Self.instance(of: $0) == instance } }
        let candidates = live.filter { $0.isParkedSpare == parked }
        return candidates.first { $0.window?.isKeyWindow == true } ?? candidates.last
    }
}
