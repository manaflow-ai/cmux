#if DEBUG
import AppKit
@testable import CmuxNextCloudUI

/// An Environment Secrets Playground view laid out in an offscreen window at a fixed size, read back as its
/// view tree (no pixels, no text recognition): the structure tests read labels, colours and shadows from it.
@MainActor
struct EnvLaidOutPage {
    let root: NSView
    private let window: NSWindow

    /// The whole playground (chrome and the model's direction) at `size`; the default is the window's size.
    init(_ model: EnvSecretsPlaygroundModel, size: CGSize = CGSize(width: 1180, height: 820)) {
        self.init(view: EnvSecretsPlaygroundView(model: model, applyLook: {}), size: size)
    }

    /// Any playground view at `size`.
    init(view: NSView, size: CGSize) {
        _ = NSApplication.shared
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        view.widthAnchor.constraint(equalToConstant: size.width).isActive = true
        view.heightAnchor.constraint(equalToConstant: size.height).isActive = true
        window.setContentSize(size)
        view.layoutSubtreeIfNeeded()
        root = view
    }

    /// Every view of type `T` under `view` (itself included), depth first.
    func all<T: NSView>(_ type: T.Type, in view: NSView? = nil) -> [T] {
        let start = view ?? root
        return ([start as? T].compactMap { $0 }) + start.subviews.flatMap { all(type, in: $0) }
    }

    /// The first label under `view` whose text starts with `prefix`.
    func label(startingWith prefix: String, in view: NSView? = nil) -> NSTextField? {
        all(NSTextField.self, in: view).first { $0.stringValue.hasPrefix(prefix) }
    }

    /// Whether `label` shows its whole text: a wrapping label is tall enough for every wrapped line, a one-line
    /// label is wide enough for the line, so neither draws an ellipsis.
    func showsInFull(_ label: NSTextField) -> Bool {
        guard let cell = label.cell else { return false }
        let bounds = label.bounds
        if cell.wraps {
            let needed = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: bounds.width, height: .greatestFiniteMagnitude))
            return needed.height <= bounds.height + 0.5
        }
        let needed = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: .greatestFiniteMagnitude, height: bounds.height))
        return needed.width <= bounds.width + 0.5
    }

    /// Whether `label` takes exactly one visual line: its height is the height of its text set on one line.
    func isOneLine(_ label: NSTextField) -> Bool {
        guard let cell = label.cell else { return false }
        let oneLine = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        return label.bounds.height <= oneLine.height + 0.5
    }
}
#endif
