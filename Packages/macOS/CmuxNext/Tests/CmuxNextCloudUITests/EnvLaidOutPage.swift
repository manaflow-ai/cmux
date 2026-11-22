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

    /// A radio row: its circle, its title, and the two vertical centres in window points.
    struct RadioRow {
        let radio: NSImageView
        let title: NSTextField
        let radioMidY: CGFloat
        let titleFirstLineMidY: CGFloat
    }

    /// Every radio row on the page: a clickable row with a title and a note (two labels or more) whose
    /// leftmost view is a square symbol in the accent colour (picked) or the tertiary label colour (not
    /// picked). The title is the row's topmost label; its first line is one line height down from its top.
    func radioRows() -> [RadioRow] {
        all(EnvClickArea.self).compactMap { area -> RadioRow? in
            let labels = all(NSTextField.self, in: area).filter { !$0.isHidden && !$0.stringValue.isEmpty }
            guard labels.count >= 2 else { return nil }
            func rect(_ view: NSView) -> CGRect { view.convert(view.bounds, to: nil) }
            guard let radio = all(NSImageView.self, in: area).min(by: { rect($0).minX < rect($1).minX }),
                  radio.contentTintColor == .controlAccentColor || radio.contentTintColor == .tertiaryLabelColor,
                  abs(rect(radio).width - rect(radio).height) < 2,
                  let title = labels.max(by: { rect($0).maxY < rect($1).maxY }), let cell = title.cell else { return nil }
            let lineHeight = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude,
                                                             height: CGFloat.greatestFiniteMagnitude)).height
            return RadioRow(radio: radio, title: title, radioMidY: rect(radio).midY, titleFirstLineMidY: rect(title).maxY - lineHeight / 2)
        }
    }

    /// Whether `label` takes exactly one visual line: its height is the height of its text set on one line.
    func isOneLine(_ label: NSTextField) -> Bool {
        guard let cell = label.cell else { return false }
        let oneLine = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        return label.bounds.height <= oneLine.height + 0.5
    }
}
#endif
