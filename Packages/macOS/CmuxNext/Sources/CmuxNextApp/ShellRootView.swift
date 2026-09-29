import AppKit
import CmuxNextDesign
import Observation
import SwiftUI

/// Full-size content view: glass sidebar on the leading edge, glass tab strip
/// across the top of the content column, and the content area below it.
///
///   +----------+---------------------------------+
///   | (lights) | tab strip (glass)               |
///   | sidebar  +---------------------------------+
///   | (glass)  | content (terminal, never glass) |
///   +----------+---------------------------------+
final class ShellRootView: NSView {
    private let model: ShellModel
    private var sidebarWidth: NSLayoutConstraint?
    private var observationTask: Task<Void, Never>?

    init(model: ShellModel, environment: AppEnvironment) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        buildHierarchy(environment: environment)
        observeSidebarVisibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    isolated deinit {
        observationTask?.cancel()
    }

    private func buildHierarchy(environment: AppEnvironment) {
        let sidebar = Glass.makePanel(content: hosting(SidebarView(model: model)))
        let tabStrip = Glass.makePanel(content: hosting(TabStripView(model: model)), cornerRadius: Metrics.itemCornerRadius + 4)
        let content = ContentPlaceholderView(tag: environment.tag)
        content.translatesAutoresizingMaskIntoConstraints = false

        addSubview(content)
        addSubview(sidebar)
        addSubview(tabStrip)

        let inset = Metrics.panelInset
        let width = sidebar.widthAnchor.constraint(equalToConstant: Metrics.sidebarWidth)
        sidebarWidth = width
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            sidebar.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            sidebar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            width,

            tabStrip.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: inset),
            tabStrip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            tabStrip.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            tabStrip.heightAnchor.constraint(equalToConstant: Metrics.tabStripHeight - inset),
            // Keep the strip clear of the traffic lights when the sidebar is hidden.
            tabStrip.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Metrics.trafficLightInset),

            content.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: tabStrip.bottomAnchor, constant: inset),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func hosting(_ view: some View) -> NSView {
        let host = NSHostingView(rootView: view)
        // The glass panel sizes the host; the host must not push back.
        host.sizingOptions = []
        return host
    }

    /// Animates the sidebar width whenever `model.isSidebarVisible` changes.
    private func observeSidebarVisibility() {
        let model = model
        observationTask = Task { [weak self] in
            for await visible in Observations({ model.isSidebarVisible }) {
                self?.applySidebar(visible: visible)
            }
        }
    }

    private func applySidebar(visible: Bool) {
        guard let sidebarWidth else { return }
        let target = visible ? Metrics.sidebarWidth : 0
        guard sidebarWidth.constant != target else { return }
        NSAnimationContext.animate(.spring(duration: 0.28, bounce: 0)) {
            sidebarWidth.animator().constant = target
            self.layoutSubtreeIfNeeded()
        }
    }
}

/// Stand-in for the terminal area until CmuxNextTerminal surfaces are fed by
/// the daemon.
final class ContentPlaceholderView: NSView {
    init(tag: String?) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Palette.contentBackground.cgColor

        let title = NSTextField(labelWithString: Strings.placeholderTitle)
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.textColor = Palette.textPrimary
        let subtitle = NSTextField(labelWithString: Strings.placeholderSubtitle)
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = Palette.textSecondary
        var rows: [NSView] = [title, subtitle]
        if let tag {
            let tagLabel = NSTextField(labelWithString: Strings.placeholderTag(tag))
            tagLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            tagLabel.textColor = Palette.textSecondary
            rows.append(tagLabel)
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Palette.contentBackground.cgColor
        }
    }
}
