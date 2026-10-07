import AppKit

/// A compact native indicator for live computer-use sessions.
public final class AgentActivityTitlebarIndicator: NSButton {
    /// Invoked after the user clicks the indicator.
    public var onPress: (() -> Void)?
    /// Number of live sessions represented by the indicator.
    public var liveCount: Int = 0 { didSet { refresh() } }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .texturedRounded
        isBordered = false
        image = NSImage(systemSymbolName: "cursorarrow.click.2", accessibilityDescription: AgentActivityStrings.live)
        target = self
        action = #selector(pressed)
        setButtonType(.momentaryPushIn)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Updates the indicator from a pane model snapshot.
    public func update(from model: AgentActivityModel) {
        liveCount = model.liveLocalCount
        accessibilityLabel = AgentActivityStrings.indicatorLabel(liveCount)
    }

    @objc private func pressed() { onPress?() }

    private func refresh() {
        title = liveCount > 0 ? " (liveCount)" : ""
        contentTintColor = liveCount > 0 ? .systemOrange : .secondaryLabelColor
        isHidden = liveCount == 0
        toolTip = AgentActivityStrings.indicatorLabel(liveCount)
    }
}
