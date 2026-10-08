import AppKit
import CmuxNextDesign

/// A `TerminalPreviewView` that follows the selected theme.
final class ThemeBoundPreview: NSView {
    private let model: ThemeStepModel
    private let preview = TerminalPreviewView()
    private var loop: RenderLoop?

    init(model: ThemeStepModel, cornerRadius: CGFloat = OnboardingMetrics.previewCornerRadius) {
        self.model = model
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        preview.layer?.cornerRadius = cornerRadius
        addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: leadingAnchor), preview.trailingAnchor.constraint(equalTo: trailingAnchor),
            preview.topAnchor.constraint(equalTo: topAnchor), preview.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        loop = RenderLoop { [weak self] in
            guard let self else { return }
            preview.input = self.model.selectedChoice.input
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// The selected theme's 16 ANSI colors as one rounded bar of segments.
final class ThemePaletteStrip: NSView {
    private let model: ThemeStepModel
    private var loop: RenderLoop?

    init(model: ThemeStepModel) {
        self.model = model
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
        loop = RenderLoop { [weak self] in
            _ = self?.model.selectedChoice
            self?.needsDisplay = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let input = model.selectedChoice.input
        let colors = input.palette.isEmpty ? [input.foreground] : input.palette
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).addClip()
        let width = bounds.width / CGFloat(colors.count)
        for (index, color) in colors.enumerated() {
            color.nsColor.setFill()
            NSRect(x: bounds.minX + CGFloat(index) * width, y: bounds.minY, width: ceil(width), height: bounds.height).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A pop-up of the theme names; picking one applies it.
final class ThemePopUp: NSPopUpButton {
    private let model: ThemeStepModel
    private var shown: [String]?
    private var loop: RenderLoop?

    init(model: ThemeStepModel) {
        self.model = model
        super.init(frame: .zero, pullsDown: false)
        translatesAutoresizingMaskIntoConstraints = false
        controlSize = .large
        target = self
        action = #selector(picked)
        loop = RenderLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func picked() {
        let index = indexOfSelectedItem
        guard model.choices.indices.contains(index) else { return }
        model.select(model.choices[index].name)
    }

    private func render() {
        let choices = model.choices
        if choices.map(\.id) != shown {
            shown = choices.map(\.id)
            removeAllItems()
            addItems(withTitles: choices.map { ThemeKit.name($0) })
        }
        let index = choices.firstIndex { $0.id == model.selectedChoice.id } ?? 0
        if indexOfSelectedItem != index { selectItem(at: index) }
    }
}
