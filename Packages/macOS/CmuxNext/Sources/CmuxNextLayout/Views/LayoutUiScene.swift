#if DEBUG
public import AppKit

/// DEBUG ONLY: the UI shell's Layout scene (Prototypes/UiLayerHost `cmux-ui-layout --shoot DIR --scene
/// layout-columns`, goal auto-ui-preview-under-60s): the real ``LayoutRootView`` with three columns, the middle
/// one split, and a docked chat column on the right, each pane a labeled tile. A push to CmuxNextLayout
/// (geometry, dividers, scroll, drop) gets its before and after from this, built without the app.
@MainActor
public enum LayoutUiScene {
    final class Tiles: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView {
            let tile = NSView()
            tile.wantsLayer = true
            tile.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            let label = NSTextField(labelWithString: pane.rawValue)
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            tile.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            ])
            return tile
        }
    }

    /// Kept for the shot: the root view holds its provider weakly.
    static var held: [AnyObject] = []

    /// Opens the scene's window (the shooter draws every window a scene opens).
    public static func show() {
        let tiles = Tiles()
        let middle: SplitNode = .split("middle", axis: .vertical, ratio: 0.6, a: .leaf("editor"), b: .leaf("terminal"))
        let layout = ScreenLayout.columns([
            LayoutColumn(id: "c1", width: 0.3, root: .leaf("browser")),
            LayoutColumn(id: "c2", width: 0.45, root: middle),
            LayoutColumn(id: "dock", width: 0.25, root: .leaf("chat"), dock: DockColumn(edge: .right)),
        ])
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "Main", layout: layout)], activeScreenID: "s",
                                focusedPane: "editor")
        let view = LayoutRootView(model: model, contentProvider: tiles)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 720), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.title = "Layout: columns"
        window.isReleasedWhenClosed = false
        view.frame = NSRect(x: 0, y: 0, width: 1200, height: 720)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        window.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
        held.append(contentsOf: [tiles, model, window])
    }
}
#endif
