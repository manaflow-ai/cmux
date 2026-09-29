public import AppKit
import CmuxNextDesign
import Observation
import SwiftUI

/// Presents the update sheet: a compact Liquid Glass panel attached as a
/// window sheet (or a standalone floating panel with no window). It resizes
/// to its content and closes itself when the source's content becomes nil
/// after having shown something (Sparkle returned to idle).
@MainActor
public final class UpdateSheetController {
    private let source: any UpdateSheetSource
    private var panel: UpdateSheetPanel?
    private var hosting: NSHostingView<UpdateSheetView>?
    private var watch: Task<Void, Never>?

    public init(source: any UpdateSheetSource) {
        self.source = source
    }

    public var isPresented: Bool { panel != nil }

    /// Shows the sheet on `window` (no-op when already shown). Never
    /// activates the app; a standalone panel orders front without focus.
    public func present(in window: NSWindow?) {
        guard panel == nil else { return }
        let panel = UpdateSheetPanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless],
                                     backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.onCancel = { [weak self] in self?.cancel() }
        let hosting = NSHostingView(rootView: UpdateSheetView(source: source, dismiss: { [weak self] in self?.dismiss() }))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        let glass = Glass.makePanel(content: hosting)
        let root = NSView()
        root.addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            glass.topAnchor.constraint(equalTo: root.topAnchor),
            glass.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        panel.contentView = root
        self.panel = panel
        self.hosting = hosting
        fit()
        if let window {
            window.beginSheet(panel)
        } else {
            panel.level = .floating
            panel.center()
            panel.orderFrontRegardless()
        }
        observe()
    }

    public func dismiss() {
        watch?.cancel()
        watch = nil
        guard let panel else { return }
        self.panel = nil
        hosting = nil
        if let parent = panel.sheetParent { parent.endSheet(panel) } else { panel.orderOut(nil) }
    }

    private func cancel() {
        guard let content = source.content else { return dismiss() }
        let button = content.buttons.first(where: \.dismisses) ?? .done
        source.perform(button)
        dismiss()
    }

    private func fit() {
        guard let panel, let hosting else { return }
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0, size != panel.frame.size else { return }
        panel.setContentSize(size)
    }

    /// Follows the source: resize on change, close on nil after content.
    private func observe() {
        let source = source
        watch = Task { [weak self] in
            var shown = false
            for await content in Observations({ source.content }) {
                guard let self, !Task.isCancelled else { return }
                if content == nil {
                    if shown { self.dismiss() }
                    continue
                }
                shown = true
                self.fit()
            }
        }
    }
}

/// Borderless sheet panel that can take key (Escape, Return) when shown.
final class UpdateSheetPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
