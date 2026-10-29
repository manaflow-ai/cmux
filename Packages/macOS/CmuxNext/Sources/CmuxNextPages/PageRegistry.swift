import AppKit

/// The live page views, for the generic page debug verb and the key dispatcher's lookups.
///
/// ``WebUIHost`` owns one; a test's host owns its own (``init()``). ``processWide`` is the registry
/// of views made with `PageWebView(...)` directly, and the app's host lists its views there too,
/// so the static lookups (the debug verbs) see every page while the static forwarders remain;
/// p13-webui-010 removes them and its static stores.
@MainActor
public final class PageRegistry {
    // The process-wide stores, as before WebUIHost (removed by p13-webui-010).
    private static let views = NSHashTable<PageWebView>.weakObjects()
    private static var serials: [ObjectIdentifier: UInt64] = [:]
    private static var nextSerial: UInt64 = 0

    /// This registry's own stores; nil for ``processWide``, which uses the static ones.
    private let ownViews: NSHashTable<PageWebView>?
    private var ownSerials: [ObjectIdentifier: UInt64] = [:]
    private var ownNextSerial: UInt64 = 0

    /// An empty registry.
    public init() {
        ownViews = .weakObjects()
    }

    private init(processWide: Void) {
        ownViews = nil
    }

    /// The registry of views made outside a ``WebUIHost`` and of the app's host, until
    /// Each read is a new handle on the same process-wide stores.
    public static var processWide: PageRegistry { PageRegistry(processWide: ()) }

    private var liveViews: NSHashTable<PageWebView> { ownViews ?? Self.views }

    /// Creation order of the live views (``instance(of:)``).
    private var order: [ObjectIdentifier: UInt64] {
        get { ownViews == nil ? Self.serials : ownSerials }
        set { if ownViews == nil { Self.serials = newValue } else { ownSerials = newValue } }
    }

    private var lastSerial: UInt64 {
        get { ownViews == nil ? Self.nextSerial : ownNextSerial }
        set { if ownViews == nil { Self.nextSerial = newValue } else { ownNextSerial = newValue } }
    }

    func add(_ view: PageWebView) {
        let views = liveViews
        guard !views.contains(view) else { return }
        views.add(view)
        lastSerial += 1
        order[ObjectIdentifier(view)] = lastSerial
        if order.count > 2 * views.count + 16 {
            let live = Set(views.allObjects.map(ObjectIdentifier.init))
            order = order.filter { live.contains($0.key) }
        }
    }

    /// Stops listing `view` (it closed).
    func remove(_ view: PageWebView) {
        liveViews.remove(view)
        order[ObjectIdentifier(view)] = nil
    }

    /// A stable number for a live view, in creation order (the `instance` of `debug.page`).
    public func instance(of view: PageWebView) -> UInt64 {
        order[ObjectIdentifier(view)] ?? 0
    }

    /// Live views of page `id` (every page when nil), oldest first.
    public func pages(id: String? = nil) -> [PageWebView] {
        let order = order
        return liveViews.allObjects.filter { id == nil || $0.pageID == id }
            .sorted { (order[ObjectIdentifier($0)] ?? 0) < (order[ObjectIdentifier($1)] ?? 0) }
    }

    /// The page a probe means: `instance` when given; else a page that is not the parked spare (the
    /// spare when `parked`), the one in the key window first, else the newest. The parked spare runs
    /// its document with no routes, so a probe that read it reported state no visible page showed.
    public func probeTarget(id: String?, parked: Bool = false, instance: UInt64? = nil) -> PageWebView? {
        let live = self.pages(id: id)
        if let instance { return live.first { self.instance(of: $0) == instance } }
        let candidates = live.filter { $0.isParkedSpare == parked }
        return candidates.first { $0.window?.isKeyWindow == true } ?? candidates.last
    }

    // MARK: Forwarders to processWide (removed by p13-webui-010)

    /// ``instance(of:)`` of ``processWide``.
    public static func instance(of view: PageWebView) -> UInt64 { processWide.instance(of: view) }

    /// ``pages(id:)`` of ``processWide``.
    public static func pages(id: String? = nil) -> [PageWebView] { processWide.pages(id: id) }

    /// ``probeTarget(id:parked:instance:)`` of ``processWide``.
    public static func probeTarget(id: String?, parked: Bool = false, instance: UInt64? = nil) -> PageWebView? {
        processWide.probeTarget(id: id, parked: parked, instance: instance)
    }
}
