import AppKit
import CmuxNextAgentPane
import CmuxNextDesign
import CmuxNextTabs

/// A terminal agent's history opens beside the PTY. The corner control shares the
/// space the presence tag and Exit Zoom already occupy, including when the tab strip is hidden.
@MainActor
final class TerminalHistoryButton: NSButton {
    let source: TerminalHistorySource
    private weak var pane: PaneController?
    private var metadata: Task<Void, Never>?
    private var fullTitle = String(localized: "terminalHistory.open", defaultValue: "Earlier history — open as chat", bundle: .module)

    init(source: TerminalHistorySource, pane: PaneController) {
        self.source = source
        self.pane = pane
        super.init(frame: .zero)
        title = fullTitle
        image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        imagePosition = .imageLeading
        bezelStyle = .accessoryBarAction
        controlSize = .small
        font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        refusesFirstResponder = true
        target = self
        action = #selector(openHistory)
        setAccessibilityLabel(fullTitle)
        toolTip = fullTitle
        metadata = Task { [weak self, weak pane] in
            guard let pane, let environment = QuitAgents.environment(pane.services),
                  let data = try? await source.read(.terminalTranscriptPage, environment: environment, params: ["metadataOnly": true]),
                  let start = data["createdMs"]?.doubleValue, let end = data["updatedMs"]?.doubleValue,
                  start > 0, end >= start, !Task.isCancelled, let self else { return }
            let calendar = Calendar.current
            let first = calendar.startOfDay(for: Date(timeIntervalSince1970: start / 1000))
            let last = calendar.startOfDay(for: Date(timeIntervalSince1970: end / 1000))
            let days = (calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1
            guard days > 1 else { return }
            fullTitle = String(localized: "terminalHistory.openDays", defaultValue: "Earlier history (\(days) days) — open as chat", bundle: .module)
            setAccessibilityLabel(fullTitle)
            toolTip = fullTitle
            superview?.needsLayout = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func discard() {
        metadata?.cancel()
        removeFromSuperview()
    }

    func place(in host: NSRect, top: CGFloat, trailing: CGFloat) -> CGFloat {
        let inset = Metrics.space2
        let room = max(0, host.width - trailing - 2 * inset)
        // In a narrow split use the same action's glyph and accessibility label.
        let label = (fullTitle as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)])
        let compact = room < label.width + 40
        let position: NSCell.ImagePosition = compact ? .imageOnly : .imageLeading
        if imagePosition != position { imagePosition = position }
        if title != fullTitle { title = fullTitle }
        let size = intrinsicContentSize
        let width = min(room, size.width)
        frame = NSRect(x: host.maxX - trailing - inset - width, y: top + inset, width: width, height: size.height)
        return trailing + width + inset
    }

    @objc private func openHistory() {
        guard let pane, pane.currentTabKey == pane.stripModel.selectedID?.rawValue,
              let id = pane.stripModel.selectedID, pane.stripModel.tab(id)?.terminalHistoryKey == source.key else { return }
        TerminalHistoryPage.open(source, in: pane)
    }
}

extension PaneController {
    func showTerminalHistoryLink(in content: TabContent?) {
        let key = stripModel.selectedID.flatMap(stripModel.tab)?.terminalHistoryKey
        guard case .terminal = content, let key else {
            view.terminalHistoryButton?.discard()
            view.terminalHistoryButton = nil
            return
        }
        let source = TerminalHistorySource(key: key, cwd: selectedTab?.cwd)
        guard view.terminalHistoryButton?.source != source else { return }
        view.terminalHistoryButton?.discard()
        let button = TerminalHistoryButton(source: source, pane: self)
        view.terminalHistoryButton = button
        view.addSubview(button, positioned: .above, relativeTo: view.agentTag)
        view.needsLayout = true
    }
}
