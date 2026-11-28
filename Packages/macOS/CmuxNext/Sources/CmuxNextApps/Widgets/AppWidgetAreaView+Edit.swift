public import AppKit
import CmuxNextDesign

/// A tile lifted in edit mode: the order the area shows while it moves, and where the pointer
/// holds it.
struct AppWidgetDrag {
    let instance: String
    var order: [AppWidgetTile]
    /// The pointer's offset from the tile's origin.
    let grab: CGSize
    var moved = false
}

/// Edit mode's gestures on the widget area: drag to arrange, the tile menu (resize, remove), and
/// the area menu (Edit Widgets, Add Widget). Every change is one `apps.widgets.layout.edit`.
extension AppWidgetAreaView {
    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard area.isEditing, let (instance, view) = tile(at: point) else { return super.mouseDown(with: event) }
        drag = AppWidgetDrag(instance: instance, order: area.tiles,
                             grab: CGSize(width: point.x - view.frame.minX, height: point.y - view.frame.minY))
        // Above the others without leaving the view tree (which would restart its feeds).
        view.layer?.zPosition = 1
    }

    public override func mouseDragged(with event: NSEvent) {
        guard var current = drag, let view = tileViews[current.instance],
              let tile = current.order.first(where: { $0.instance == current.instance }) else { return super.mouseDragged(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        current.moved = true
        view.isLifted = true
        view.setFrameOrigin(CGPoint(x: point.x - current.grab.width, y: point.y - current.grab.height))
        // Where it lands among the others, by the lifted tile's center.
        var others = current.order
        others.removeAll { $0.instance == current.instance }
        let frames = grid.layout(others.map(\.size), width: bounds.width).frames
        let index = grid.dropIndex(at: CGPoint(x: view.frame.midX, y: view.frame.midY), in: frames)
        others.insert(tile, at: index)
        let reordered = others.map(\.instance) != current.order.map(\.instance)
        current.order = others
        drag = current
        if reordered { layoutTiles(animated: true) }
    }

    public override func mouseUp(with event: NSEvent) {
        guard let ended = drag else { return super.mouseUp(with: event) }
        drag = nil
        tileViews[ended.instance]?.isLifted = false
        tileViews[ended.instance]?.layer?.zPosition = 0
        let before = ended.order.firstIndex { $0.instance == ended.instance }.flatMap { index in
            ended.order.indices.contains(index + 1) ? ended.order[index + 1].instance : nil
        }
        let old = area.tiles.firstIndex { $0.instance == ended.instance }
        let new = ended.order.firstIndex { $0.instance == ended.instance }
        if ended.moved, old != new {
            area.edit(.move(instance: ended.instance, before: before))
        } else {
            layoutTiles(animated: true)
        }
    }

    /// The tile under `point`.
    func tile(at point: CGPoint) -> (String, AppWidgetTileView)? {
        tileViews.first { $0.value.frame.contains(point) }.map { ($0.key, $0.value) }
    }

    // MARK: Menus

    public override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let menu = NSMenu()
        if let (instance, _) = tile(at: point), let placed = area.tiles.first(where: { $0.instance == instance }) {
            for size in area.catalog.spec(placed.app)?.sidebarSizes ?? [] {
                let item = AppWidgetMenuItem(title: AppWidgetStrings.size(size)) { [weak self] in
                    self?.area.edit(.resize(instance: instance, size: size))
                }
                item.state = size == placed.size ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(AppWidgetMenuItem(title: AppWidgetStrings.remove) { [weak self] in self?.area.edit(.remove(instance: instance)) })
            menu.addItem(.separator())
        }
        for item in areaMenuItems() { menu.addItem(item) }
        return NSMenu.withoutSystemItems(menu)
    }

    /// The area's own items (also the section header's menu): Edit Widgets or Done, Add Widget.
    public func areaMenuItems() -> [NSMenuItem] {
        let editing = area.isEditing
        return [
            AppWidgetMenuItem(title: editing ? AppWidgetStrings.done : AppWidgetStrings.edit) { [weak self] in
                if editing { self?.endEditing() } else { self?.area.isEditing = true }
            },
            AppWidgetMenuItem(title: AppWidgetStrings.add) { [weak self] in self?.openGallery() },
        ]
    }
}

/// A menu item that runs a closure (it is its own target, so the menu keeps it alive; AppKit calls
/// menu actions on the main thread).
nonisolated final class AppWidgetMenuItem: NSMenuItem {
    private let run: @MainActor @Sendable () -> Void

    init(title: String, _ run: @escaping @MainActor @Sendable () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() {
        let run = run
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated { run() } // main-proof: guarded by Thread.isMainThread above
    }
}
