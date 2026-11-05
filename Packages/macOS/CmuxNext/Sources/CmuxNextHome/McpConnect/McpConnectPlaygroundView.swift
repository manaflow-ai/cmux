#if DEBUG
import AppKit
import CmuxNextCompat
import CmuxNextDesign

/// DEBUG ONLY: the MCP Connect Card Playground's content: pickers on top, then the same card in a
/// light and a dark theme side by side. The cards are live: Connect, Cancel, the scope menu and the
/// key field step the real ``McpConnectCardFlow``; "Finish sign-in" plays the daemon's part.
final class McpConnectPlaygroundView: NSView {
    private let model: McpConnectPlaygroundModel
    private let style = NSPopUpButton()
    private let fixture = NSPopUpButton()
    private let phase = NSPopUpButton()
    private let finish = NSButton(title: "Finish sign-in", target: nil, action: nil)
    private let columns = [NSView(), NSView()]
    private(set) var cards: [McpConnectCardView] = []
    private var shownGeneration = -1
    // task-owner: the view's `following`, started when it joins a window and cancelled when it leaves.
    private var following: Task<Void, Never>?

    init(model: McpConnectPlaygroundModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 1180, height: 560))
        build()
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func build() {
        for (button, titles) in [(style, McpConnectCardStyle.allCases.map { "\($0.rawValue). \($0.title)" }),
                                 (fixture, McpConnectCardFixture.allCases.map(\.title)),
                                 (phase, McpConnectPlaygroundPhase.allCases.map(\.title))] {
            button.addItems(withTitles: titles)
            button.target = self
            button.action = #selector(picked)
        }
        finish.target = self
        finish.action = #selector(finishSignIn)
        let pickers = NSStackView(views: [labeled("Style", style), labeled("Server", fixture), labeled("Phase", phase), finish])
        pickers.orientation = .horizontal
        pickers.spacing = 12
        pickers.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pickers)
        let tokens = [McpConnectPlaygroundModel.lightTokens, McpConnectPlaygroundModel.darkTokens]
        for (index, column) in columns.enumerated() {
            column.wantsLayer = true
            column.layer?.backgroundColor = tokens[index].contentBackground.nsColor.cgColor
            column.translatesAutoresizingMaskIntoConstraints = false
            addSubview(column)
        }
        NSLayoutConstraint.activate([
            pickers.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            pickers.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            columns[0].topAnchor.constraint(equalTo: pickers.bottomAnchor, constant: 12),
            columns[0].leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            columns[0].bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            columns[1].topAnchor.constraint(equalTo: columns[0].topAnchor),
            columns[1].bottomAnchor.constraint(equalTo: columns[0].bottomAnchor),
            columns[1].leadingAnchor.constraint(equalTo: columns[0].trailingAnchor),
            columns[1].trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            columns[1].widthAnchor.constraint(equalTo: columns[0].widthAnchor),
        ])
    }

    private func labeled(_ title: String, _ control: NSView) -> NSView {
        let stack = NSStackView(views: [NSTextField(labelWithString: title), control])
        stack.spacing = 6
        return stack
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        following?.cancel()
        following = nil
        guard window != nil else { return }
        render()
        let model = model
        following = Task { [weak self] in
            for await _ in ObservationStream({ _ = model.flow; _ = model.generation; _ = model.style; _ = model.fixture; _ = model.phase }) {
                guard let self, !Task.isCancelled else { return }
                self.render()
            }
        }
    }

    /// Reads the model: the pickers, Finish sign-in, and the two cards (new ones on a rebuild, so
    /// they drop their own state, as the SwiftUI `.id` did; the same ones one step on otherwise).
    func render() {
        style.selectItem(at: McpConnectCardStyle.allCases.firstIndex(of: model.style) ?? 0)
        fixture.selectItem(at: McpConnectCardFixture.allCases.firstIndex(of: model.fixture) ?? 0)
        phase.selectItem(at: McpConnectPlaygroundPhase.allCases.firstIndex(of: model.phase) ?? 0)
        finish.isEnabled = model.flow.phase == .signingIn || model.flow.phase == .connecting
        guard model.generation == shownGeneration, cards.count == columns.count else { return rebuildCards() }
        for card in cards { card.show(model.flow) }
    }

    private func rebuildCards() {
        shownGeneration = model.generation
        for card in cards { card.removeFromSuperview() }
        cards = zip(columns, [McpConnectPlaygroundModel.light, McpConnectPlaygroundModel.dark]).map { column, colors in
            let card = McpConnectCardView(flow: model.flow, style: model.style, colors: colors, actions: model.actions)
            column.addSubview(card)
            let fill = card.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -36)
            fill.priority = .defaultHigh
            NSLayoutConstraint.activate([
                card.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 18),
                card.topAnchor.constraint(equalTo: column.topAnchor, constant: 18),
                card.bottomAnchor.constraint(lessThanOrEqualTo: column.bottomAnchor, constant: -18),
                fill,
            ])
            return card
        }
    }

    @objc private func picked() {
        model.select(style: McpConnectCardStyle.allCases[safe: style.indexOfSelectedItem],
                     fixture: McpConnectCardFixture.allCases[safe: fixture.indexOfSelectedItem],
                     phase: McpConnectPlaygroundPhase.allCases[safe: phase.indexOfSelectedItem])
        render()
    }

    @objc private func finishSignIn() {
        model.finishSignIn()
        render()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
#endif
