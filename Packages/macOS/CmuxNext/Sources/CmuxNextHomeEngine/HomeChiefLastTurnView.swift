import AppKit
import CmuxNextDaemon
import CmuxNextDesign

/// The Diagnostics card's last turn (Leo 2026-10-21, #89: Diagnostics was a text dump): the
/// engine by name and when the turn ended, then its time, cost (or tokens), cache share and tool
/// calls as four measures side by side, and the error a failed turn ended with. With no turn yet
/// it says what will show here. VoiceOver reads it as one sentence (``HomeEngineStrings/lastTurn(_:models:)``).
@MainActor
final class HomeChiefLastTurnView: NSView {
    let engine = ThemedLabel(labelWithString: "")
    let ended = ThemedLabel(labelWithString: "")
    let empty = ThemedLabel(wrappingLabelWithString: HomeChiefCardStrings.noTurnHelp)
    let error = ThemedLabel(wrappingLabelWithString: "")
    private(set) var tiles: [HomeChiefMetricTile] = []
    private let tileRow = NSStackView()
    private let stack = NSStackView()
    /// The summary shown, nil with no turn yet (tests).
    private(set) var summary: HomeChiefTurnSummary?

    init(wrapWidth: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("cmux.home.chief.lastTurn")
        engine.font = Typography.bodyEmphasized
        engine.lineBreakMode = .byTruncatingTail
        engine.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        ended.font = Typography.caption
        ended.ink = .tertiary
        ended.setContentHuggingPriority(.required, for: .horizontal)
        let top = NSStackView(views: [engine, ended])
        top.orientation = .horizontal
        top.alignment = .firstBaseline
        top.spacing = Metrics.space2
        tileRow.orientation = .horizontal
        tileRow.distribution = .fillEqually
        tileRow.spacing = Metrics.space2
        for label in [empty, error] {
            label.font = Typography.caption
            label.preferredMaxLayoutWidth = wrapWidth
        }
        empty.ink = .secondary
        error.ink = .danger
        error.maximumNumberOfLines = 3
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for view in [top, tileRow, error, empty] {
            view.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        show(nil, models: [])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    nonisolated override var isFlipped: Bool { true }

    /// Shows `turn` (nil: no turn yet), naming its model from `models`.
    func show(_ turn: HomeEngineTurn?, models: [ChiefEngineReport.Model]) {
        let summary = turn.map { HomeChiefTurnSummary($0, models: models) }
        self.summary = summary
        engine.stringValue = summary?.engine ?? HomeEngineStrings.noTurn
        engine.ink = summary == nil ? .secondary : .primary
        ended.stringValue = summary?.ended ?? ""
        ended.isHidden = summary?.ended == nil
        let metrics = summary?.metrics ?? []
        if tiles.count != metrics.count {
            tiles.forEach { $0.removeFromSuperview() }
            tiles = metrics.map { _ in HomeChiefMetricTile() }
            for tile in tiles { tileRow.addArrangedSubview(tile) }
        }
        for (tile, metric) in zip(tiles, metrics) { tile.show(metric) }
        tileRow.isHidden = metrics.isEmpty
        error.stringValue = summary?.error ?? ""
        error.isHidden = summary?.error == nil
        empty.isHidden = summary != nil
        setAccessibilityLabel(turn.map { HomeEngineStrings.lastTurn($0, models: models) } ?? HomeEngineStrings.noTurn)
    }
}

/// One measure of the last turn: its value large over its name, on a quiet rounded fill.
@MainActor
final class HomeChiefMetricTile: NSView {
    let value = ThemedLabel(labelWithString: "")
    let label = ThemedLabel(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
        value.font = Typography.system(.monospacedDigit, size: Typography.body.pointSize, weight: .semibold)
        label.font = Typography.caption
        label.ink = .secondary
        for text in [value, label] {
            text.lineBreakMode = .byTruncatingTail
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            text.translatesAutoresizingMaskIntoConstraints = false
            addSubview(text)
        }
        let inset = Metrics.space2
        NSLayoutConstraint.activate([
            value.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            value.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            value.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),
            label.topAnchor.constraint(equalTo: value.bottomAnchor, constant: 2),
            label.leadingAnchor.constraint(equalTo: value.leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    nonisolated override var isFlipped: Bool { true }
    nonisolated override var wantsUpdateLayer: Bool { true }

    func show(_ metric: HomeChiefTurnSummary.Metric) {
        value.stringValue = metric.value
        // A note ("1 failed") takes the name's place in the danger ink; the tooltip says both.
        label.stringValue = metric.note ?? metric.label
        label.ink = metric.note == nil ? .secondary : .danger
        themedToolTip = metric.note.map { "\(metric.label): \(metric.value), \($0)" }
    }

    override func updateLayer() {
        layer?.cornerRadius = Metrics.itemCornerRadius
        layer?.cornerCurve = .continuous
        performWithTheme { layer?.backgroundColor = Palette.hoverFill.cgColor }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsDisplay = true
    }
}
