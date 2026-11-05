import AppKit
import CmuxNextCompat
import QuartzCore

/// SCRATCH (never merge; cmux-ad m20 item 6, the per-commit probe for pages): `debug.frames` actions `pages_start` and
/// `pages_stop`.
///
/// After each main-thread Core Animation commit (a run-loop observer one order after Core Animation's, 2,000,001) it
/// reads, per shown Chromium page, what that commit showed, in window points (AppKit, bottom-left origin):
/// - `pane`: the page's pane (`PaneHostView`) frame;
/// - `tab`: the page's tab content view (`CEFTabContentView`) frame, and `host` the `CEFHostView` frame;
/// - `hosted_view`: the `CEFHostedPageView` frame (its root layer holds the `CALayerHost`);
/// - `layer_host`: that `CALayerHost`'s frame in the hosted view's root (unflipped);
/// - `hosted_root`: the root layer of the context the `CALayerHost` shows (the fork's layer; that `CAContext` lives in
///   this process, as `debug.layers` reads it): frame and bounds;
/// - `gpu`: each layer under the hosted root to depth 4: class, frame in the hosted root's space, bounds. Chromium's
///   GPU output is the `CALayerHost` there (`ui::DisplayCALayerTree`), sized from the last frame the page delivered.
/// A page gets a record only when one of these changed since its last record; `dividers` (the mid x of each vertical
/// `DividerHandleView` in window points) come with every record. The views are found by class name (this package
/// cannot name them) when recording starts and every ``rescanEvery`` commits, not in every commit.
@MainActor
final class PageCommitProbe {
    private var observer: CFRunLoopObserver?
    private var records: [[String: Any]] = []
    private var last: [ObjectIdentifier: [Double]] = [:]
    private var pages: [Weak] = []
    private var dividers: [Weak] = []
    private var commits = 0
    private var started: CFTimeInterval = 0
    private let limit = 60000
    private let rescanEvery = 120

    private struct Weak { weak var view: NSView? }

    func start() {
        stop()
        records = []
        last = [:]
        commits = 0
        started = CACurrentMediaTime()
        rescan()
        let observer = MainRunLoopObserver.afterCommitObserver(activities: [.beforeWaiting, .exit], order: 2_000_001) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() } // main-proof: added to the main run loop only (below)
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    func stopAndRead() -> [String: Any] {
        let out: [String: Any] = ["commits": commits, "pages_found": pages.count, "records": records, "truncated": records.count >= limit]
        stop()
        records = []
        return out
    }

    private func stop() {
        if let observer { CFRunLoopObserverInvalidate(observer) }
        observer = nil
    }

    private func rescan() {
        var found: [NSView] = []
        var handles: [NSView] = []
        for window in NSApp.windows where window.isVisible {
            guard let root = window.contentView?.superview ?? window.contentView else { continue }
            Self.collect(root, into: &found, handles: &handles)
        }
        pages = found.map { Weak(view: $0) }
        dividers = handles.map { Weak(view: $0) }
    }

    private static func collect(_ view: NSView, into pages: inout [NSView], handles: inout [NSView]) {
        let name = NSStringFromClass(type(of: view))
        if name.hasSuffix("CEFTabContentView") { pages.append(view) }
        if name.hasSuffix("DividerHandleView") { handles.append(view) }
        for sub in view.subviews { collect(sub, into: &pages, handles: &handles) }
    }

    private func sample() {
        guard records.count < limit else { return }
        commits += 1
        if commits % rescanEvery == 0 { rescan() }
        let t = (CACurrentMediaTime() - started) * 1000
        var dividerXs: [Double]?
        for entry in pages {
            guard let tab = entry.view, let window = tab.window, !tab.isHiddenOrHasHiddenAncestor else { continue }
            var values: [Double] = []
            var fields: [String: Any] = [:]
            func put(_ key: String, _ view: NSView?) {
                guard let view else { return }
                let r = Self.rect(view.convert(view.bounds, to: nil))
                fields[key] = r
                values += r
            }
            put("pane", Self.ancestor(of: tab, suffix: "PaneHostView"))
            put("tab", tab)
            put("host", Self.descendant(of: tab, suffix: "CEFHostView"))
            let hosted = Self.descendant(of: tab, suffix: "CEFHostedPageView")
            put("hosted_view", hosted)
            if let layerHost = Self.firstLayerHost(hosted?.layer) {
                fields["layer_host"] = Self.rect(layerHost.frame)
                values += Self.rect(layerHost.frame)
                if let root = Self.hostedRoot(of: layerHost) {
                    fields["hosted_root"] = ["frame": Self.rect(root.frame), "bounds": Self.rect(root.bounds), "flipped": root.isGeometryFlipped] as [String: Any]
                    values += Self.rect(root.frame) + Self.rect(root.bounds)
                    var tree: [[String: Any]] = []
                    Self.walk(root, in: root, depth: 1, into: &tree, values: &values)
                    fields["gpu"] = tree
                }
            }
            let key = ObjectIdentifier(tab)
            guard last[key] != values else { continue }
            last[key] = values
            if dividerXs == nil {
                dividerXs = dividers.compactMap(\.view).filter { $0.window === window && $0.bounds.height > $0.bounds.width }
                    .map { Double($0.convert($0.bounds, to: nil).midX) }.sorted()
            }
            fields["page"] = key.hashValue & 0xFFFFF
            fields["t_ms"] = (t * 100).rounded() / 100
            fields["commit"] = commits
            fields["dividers"] = dividerXs ?? []
            fields["scale"] = Double(window.backingScaleFactor)
            records.append(fields)
        }
    }

    private static func walk(_ layer: CALayer, in root: CALayer, depth: Int, into tree: inout [[String: Any]], values: inout [Double]) {
        guard depth <= 4 else { return }
        for sub in layer.sublayers ?? [] {
            let frame = root.convert(sub.frame, from: layer)
            tree.append(["depth": depth, "class": NSStringFromClass(type(of: sub)), "frame": rect(frame), "bounds": rect(sub.bounds),
                         "hidden": sub.isHidden])
            values += rect(frame) + rect(sub.bounds)
            walk(sub, in: root, depth: depth + 1, into: &tree, values: &values)
        }
    }

    private static func rect(_ r: CGRect) -> [Double] {
        [r.minX, r.minY, r.width, r.height].map { (Double($0) * 100).rounded() / 100 }
    }

    private static func ancestor(of view: NSView, suffix: String) -> NSView? {
        var current = view.superview
        while let candidate = current {
            if NSStringFromClass(type(of: candidate)).hasSuffix(suffix) { return candidate }
            current = candidate.superview
        }
        return nil
    }

    private static func descendant(of view: NSView, suffix: String) -> NSView? {
        for sub in view.subviews {
            if NSStringFromClass(type(of: sub)).hasSuffix(suffix) { return sub }
            if let found = descendant(of: sub, suffix: suffix) { return found }
        }
        return nil
    }

    private static func firstLayerHost(_ layer: CALayer?) -> CALayer? {
        guard let layer else { return nil }
        if NSStringFromClass(type(of: layer)) == "CALayerHost" { return layer }
        return (layer.sublayers ?? []).lazy.compactMap { firstLayerHost($0) }.first
    }

    /// The root layer of the context `host` shows, when that context is in this process (as `debug.layers` reads it).
    /// Every QuartzCore SPI message is sent only after `responds(to:)`.
    private static func hostedRoot(of host: CALayer) -> CALayer? {
        let contextIdGetter = #selector(getter: PageCommitQuartzSPI.contextId)
        let rootLayerGetter = #selector(getter: PageCommitQuartzSPI.layer)
        guard host.responds(to: contextIdGetter) else { return nil }
        let id = unsafeBitCast(host, to: PageCommitQuartzSPI.self).contextId
        guard id != 0, let contextClass: AnyClass = NSClassFromString("CAContext"),
              (contextClass as AnyObject).responds(to: #selector(PageCommitQuartzSPI.allContexts)),
              let contexts = (contextClass as AnyObject).perform(#selector(PageCommitQuartzSPI.allContexts))?
                  .takeUnretainedValue() as? [NSObject] else { return nil }
        for context in contexts {
            guard context.responds(to: contextIdGetter) else { continue }
            guard context.responds(to: rootLayerGetter) else { continue }
            let spi = unsafeBitCast(context, to: PageCommitQuartzSPI.self)
            guard spi.contextId == id else { continue }
            return spi.layer
        }
        return nil
    }
}

/// `+[CAContext allContexts]`, `-[CAContext contextId]`, `-[CAContext layer]`, `-[CALayerHost contextId]`.
@objc private protocol PageCommitQuartzSPI {
    func allContexts() -> [NSObject]?
    var contextId: UInt32 { get }
    var layer: CALayer? { get }
}
