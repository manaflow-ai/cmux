import AppKit
import CmuxNextDesign

/// The agent pane's tab strip and content (user 2026-11-03, msg 19960): one tab per opened agent, the
/// selected tab's content under it. Opening an agent that has a tab selects it; closing the last tab calls
/// `emptied`. With ``onSelect`` and ``onClose`` set (``HomeAgentPaneView``) a tab click or its close button
/// asks the owner instead, which then calls ``select(_:)`` or ``close(_:)``; the DEBUG playground leaves them nil.
@MainActor
final class HomeAgentSidePane: NSView {
    private struct Tab {
        let peer: String
        let title: String
        let content: NSView
        let chip: NSView
    }

    var emptied: (() -> Void)?
    /// A click on a tab (nil: the tab shows at once).
    var onSelect: ((String) -> Void)?
    /// A click on a tab's close button (nil: the tab closes at once).
    var onClose: ((String) -> Void)?
    private var tabs: [Tab] = []
    private var selected: String?
    private let strip = NSStackView()
    private let holder = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        strip.spacing = 4
        strip.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        strip.alignment = .centerY
        let line = NSBox()
        line.boxType = .separator
        for view in [strip, line, holder] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: topAnchor),
            strip.leadingAnchor.constraint(equalTo: leadingAnchor),
            strip.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            strip.heightAnchor.constraint(equalToConstant: 36),
            line.topAnchor.constraint(equalTo: strip.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            holder.topAnchor.constraint(equalTo: line.bottomAnchor),
            holder.leadingAnchor.constraint(equalTo: leadingAnchor),
            holder.trailingAnchor.constraint(equalTo: trailingAnchor),
            holder.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The opened agents, in tab order.
    var peers: [String] { tabs.map(\.peer) }

    /// Selects `peer`'s tab, or adds one with `content()` and selects it.
    func open(_ peer: String, title: String, content: () -> NSView) {
        if !tabs.contains(where: { $0.peer == peer }) {
            let chip = makeChip(peer: peer, title: title)
            tabs.append(Tab(peer: peer, title: title, content: content(), chip: chip))
            strip.addArrangedSubview(chip)
        }
        select(peer)
    }

    /// Puts `content` in `peer`'s tab in place of its old content (its chat changed), and `title` on its tab.
    func replace(_ peer: String, title: String, content: NSView) {
        guard let index = tabs.firstIndex(where: { $0.peer == peer }) else { return }
        let old = tabs[index]
        if old.content.superview === holder { old.content.removeFromSuperview() }
        ((old.chip.subviews.first as? NSStackView)?.arrangedSubviews.first as? NSButton)?.title = title
        tabs[index] = Tab(peer: peer, title: title, content: content, chip: old.chip)
        if selected == peer { select(peer) }
    }

    /// Puts `title` on `peer`'s tab (its content stays).
    func retitle(_ peer: String, title: String) {
        guard let index = tabs.firstIndex(where: { $0.peer == peer }), tabs[index].title != title else { return }
        let old = tabs[index]
        ((old.chip.subviews.first as? NSStackView)?.arrangedSubviews.first as? NSButton)?.title = title
        tabs[index] = Tab(peer: peer, title: title, content: old.content, chip: old.chip)
    }

    /// `peer`'s tab content; nil when it has no tab.
    func content(of peer: String) -> NSView? { tabs.first { $0.peer == peer }?.content }

    /// The selected tab's content.
    var selectedContent: NSView? { tabs.first { $0.peer == selected }?.content }

    /// Shows `peer`'s tab.
    func select(_ peer: String) {
        guard let tab = tabs.first(where: { $0.peer == peer }) else { return }
        selected = peer
        holder.subviews.forEach { $0.removeFromSuperview() }
        tab.content.frame = holder.bounds
        tab.content.autoresizingMask = [.width, .height]
        tab.content.translatesAutoresizingMaskIntoConstraints = true
        holder.addSubview(tab.content)
        for other in tabs {
            (other.chip as? HomeAgentFillView)?.fill = other.peer == peer ? .quaternaryLabelColor.withAlphaComponent(0.22) : .clear
        }
    }

    /// Closes `peer`'s tab (the next one shows; none left: `emptied`).
    func close(_ peer: String) {
        guard let index = tabs.firstIndex(where: { $0.peer == peer }) else { return }
        let tab = tabs.remove(at: index)
        tab.chip.removeFromSuperview()
        if tab.content.superview === holder { tab.content.removeFromSuperview() }
        if !tabs.isEmpty {
            if selected == peer { select(tabs[min(index, tabs.count - 1)].peer) }
        } else {
            selected = nil
            emptied?()
        }
    }

    /// Closes every tab.
    func closeAll() {
        for peer in peers { close(peer) }
    }

    private func makeChip(peer: String, title: String) -> NSView {
        let chip = HomeAgentFillView(fill: .clear, radius: 7)
        let name = TabButton(title: title, target: self, action: #selector(tabClicked))
        name.peer = peer
        name.isBordered = false
        name.font = Typography.system(size: TypeScale.detail, weight: TypeScale.emphasis)
        name.lineBreakMode = .byTruncatingTail
        let closeLabel = String(localized: "home.agentPane.closeTab", defaultValue: "Close tab", bundle: .module)
        let closeButton = TabButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: closeLabel) ?? NSImage(),
                                    target: self, action: #selector(closeClicked))
        closeButton.peer = peer
        closeButton.isBordered = false
        closeButton.symbolConfiguration = .init(pointSize: 9, weight: TypeScale.emphasis)
        closeButton.contentTintColor = .secondaryLabelColor
        let row = NSStackView(views: [name, closeButton])
        row.spacing = 4
        row.edgeInsets = NSEdgeInsets(top: 3, left: 10, bottom: 3, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: chip.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: chip.trailingAnchor),
            row.topAnchor.constraint(equalTo: chip.topAnchor),
            row.bottomAnchor.constraint(equalTo: chip.bottomAnchor),
            name.widthAnchor.constraint(lessThanOrEqualToConstant: 150),
        ])
        return chip
    }

    @objc private func tabClicked(_ sender: TabButton) {
        if let onSelect { onSelect(sender.peer) } else { select(sender.peer) }
    }

    @objc private func closeClicked(_ sender: TabButton) {
        if let onClose { onClose(sender.peer) } else { close(sender.peer) }
    }
}

/// A tab strip button that knows its agent.
private final class TabButton: NSButton {
    var peer = ""
}
