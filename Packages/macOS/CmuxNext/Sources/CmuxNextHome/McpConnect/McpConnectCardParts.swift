import AppKit
import CmuxNextDesign

/// The pieces every card style is made of: the facts, the risk lines, the scope menu, the buttons,
/// the private key field and the phase line. Each style arranges them; none adds a fact of its own.
///
/// AppKit views, made from the card's flow, colors and actions and the card view's own state (an
/// open disclosure, the typed key). A part that changes that state asks the card to draw again.
@MainActor
struct McpConnectParts {
    let flow: McpConnectCardFlow
    let colors: McpConnectCardColors
    let actions: McpConnectCardActions
    let state: McpConnectCardState

    var card: McpConnectCard { flow.card }

    // MARK: Text

    func label(_ text: String, font: NSFont, color: NSColor, lines: Int = 1, selectable: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = color
        label.maximumNumberOfLines = lines
        label.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        label.cell?.truncatesLastVisibleLine = true
        label.isSelectable = selectable
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    /// A vertical stack. With `fill`, every part but a pull-down runs the stack's width, so a row's
    /// spacer pushes its buttons to the trailing edge and a long line wraps at the card's edge.
    func column(_ views: [NSView], spacing: CGFloat, alignment: NSLayoutConstraint.Attribute = .leading,
                fill: Bool = true) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = alignment
        stack.spacing = spacing
        if fill {
            for view in views where !(view is NSPopUpButton) {
                view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
        return stack
    }

    func row(_ views: [NSView], spacing: CGFloat, alignment: NSLayoutConstraint.Attribute = .centerY) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = alignment
        stack.distribution = .fill
        stack.spacing = spacing
        return stack
    }

    /// A view that takes the free width of its row.
    func spacer(min: CGFloat = 0) -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: min).isActive = true
        return spacer
    }

    /// An SF Symbol tinted `color`, at the caption's size.
    func symbol(_ name: String, color: NSColor, size: CGFloat? = nil) -> NSImageView {
        let image = NSImageView()
        let configuration = NSImage.SymbolConfiguration(pointSize: size ?? colors.caption.pointSize, weight: .regular)
        image.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        image.contentTintColor = color
        image.setContentHuggingPriority(.required, for: .horizontal)
        return image
    }

    /// A symbol before a line (SwiftUI's `Label`).
    func iconLine(_ text: String, symbol name: String, font: NSFont, color: NSColor) -> NSStackView {
        let text = label(text, font: font, color: color, lines: 0)
        return row([symbol(name, color: color, size: font.pointSize), text], spacing: 6)
    }

    // MARK: Facts

    /// The facts as a two-column grid: the server or command, the binary, the publisher, the access.
    func facts() -> NSView {
        var rows: [(String, String, Bool)] = []
        switch card.transport {
        case .remote(let url):
            rows.append((McpConnectStrings.server, url, true))
        case .local(let argv, let sha, _):
            rows.append((McpConnectStrings.command, argv.joined(separator: " "), true))
            rows.append((McpConnectStrings.binary, "sha256:" + sha.prefix(16) + "…", true))
        }
        rows.append((McpConnectStrings.by, card.publisher, false))
        rows.append((McpConnectStrings.access, McpConnectAccessText(card: card).text, false))
        let grid = NSGridView(views: rows.map { name, value, mono in
            let value = label(value, font: mono ? colors.mono : colors.body, color: colors.text, lines: 2, selectable: true)
            value.lineBreakMode = .byTruncatingMiddle
            return [label(name, font: colors.caption, color: colors.tertiary), value]
        })
        grid.columnSpacing = 12
        grid.rowSpacing = 4
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .leading
        return grid
    }

    /// The lines that say why to look twice.
    var riskLines: [String] {
        var out: [String] = []
        if case .local(_, _, let fetches) = card.transport {
            out.append(McpConnectStrings.riskLocal)
            if fetches { out.append(McpConnectStrings.riskFetches) }
        } else if !card.verified {
            out.append(McpConnectStrings.riskUnverified)
        }
        if card.idn { out.append(McpConnectStrings.riskIDN) }
        return out + card.warnings
    }

    /// The risk lines; hidden (and so out of its stack) when there are none.
    func risks() -> NSView {
        let lines = riskLines
        let stack = column(lines.map { iconLine($0, symbol: "exclamationmark.triangle", font: colors.caption, color: colors.attention) },
                           spacing: 2)
        stack.isHidden = lines.isEmpty
        return stack
    }

    /// The badge: Verified (registry, exact URL) or Unverified.
    func badge() -> NSView {
        let ok = card.verified && !card.idn
        return iconLine(ok ? McpConnectStrings.verified : McpConnectStrings.unverified,
                        symbol: ok ? "checkmark.seal" : "questionmark.diamond", font: colors.caption,
                        color: ok ? colors.secondary : colors.attention)
    }

    /// "Chief asks: …", the agent's own sentence in quotes; nil without a reason.
    func reason(centered: Bool = false) -> NSView? {
        guard !card.reason.isEmpty else { return nil }
        let text = NSMutableAttributedString(string: McpConnectStrings.asks(card.agent) + " ",
                                             attributes: [.font: colors.body, .foregroundColor: colors.tertiary])
        text.append(NSAttributedString(string: "“" + card.reason + "”", attributes: [.font: colors.body, .foregroundColor: colors.secondary]))
        let label = NSTextField(labelWithAttributedString: text)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.alignment = centered ? .center : .natural
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    /// The server's mark: the first letter on a gray tile (no brand art is bundled).
    func mark(size: CGFloat) -> NSView {
        let tile = NSView()
        tile.wantsLayer = true
        tile.layer?.cornerRadius = size * 0.24
        tile.layer?.cornerCurve = .continuous
        tile.layer?.backgroundColor = colors.fill.cgColor
        let letter = label(String(card.title.prefix(1)).uppercased(),
                           font: Typography.system(.default, size: size * 0.5, weight: .semibold), color: colors.text)
        letter.alignment = .center
        letter.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(letter)
        tile.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: size), tile.heightAnchor.constraint(equalToConstant: size),
            letter.centerXAnchor.constraint(equalTo: tile.centerXAnchor), letter.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])
        return tile
    }

    // MARK: Controls

    /// Who gets the server: a borderless pull-down of the scopes.
    func scopeMenu() -> NSView {
        McpConnectScopeButton(scope: flow.scope, colors: colors) { [actions] scope in actions.choose(scope) }
    }

    /// A dialog button showing and binding `hint` (Return or Escape), as in every cmux dialog.
    func dialogButton(_ title: String, id: String, hint: CmuxDialogKeyHint, enabled: Bool = true,
                      action: @escaping @MainActor () -> Void) -> NSView {
        let role: CmuxDialogButton.Role = hint == .escape ? .cancel : .default
        let runner = state.hold(McpConnectButton(action: action))
        let view = CmuxDialogButtonView(standalone: CmuxDialogButton(id: id, title: title, role: role), target: runner,
                                        action: #selector(McpConnectButton.run))
        view.isEnabled = enabled
        return view
    }

    /// A plain button that runs `action`.
    func plainButton(_ title: String, borderless: Bool = false, action: @escaping @MainActor () -> Void) -> NSButton {
        let runner = state.hold(McpConnectButton(action: action))
        let button = NSButton(title: title, target: runner, action: #selector(McpConnectButton.run))
        button.bezelStyle = borderless ? .inline : .push
        if borderless { button.isBordered = false }
        button.font = colors.body
        return button
    }

    /// Cancel and Connect (Return), or the private key field, or the phase line, by phase.
    func controls() -> NSView {
        switch flow.phase {
        case .ask:
            return row([spacer(),
                        dialogButton(McpConnectStrings.cancel, id: "cancel", hint: .escape) { [actions] in actions.cancel() },
                        dialogButton(McpConnectStrings.connect, id: "connect", hint: .return) { [actions] in actions.connect() }],
                       spacing: 8)
        case .enterKey:
            return keyEntry()
        case .signingIn:
            return phaseLine(McpConnectStrings.signingIn)
        case .connecting:
            return phaseLine(McpConnectStrings.connecting)
        case .connected(let tools):
            return toolList(tools)
        case .declined:
            return label(McpConnectStrings.declined, font: colors.caption, color: colors.tertiary)
        case .failed(let reason):
            return label(McpConnectStrings.failed(reason), font: colors.caption, color: colors.danger, lines: 0)
        }
    }

    /// The private key field, its note, then Skip (an optional key), Cancel and Save.
    private func keyEntry() -> NSView {
        let name: String = if case .key(let name, _) = card.auth { name } else { "" }
        let field = NSSecureTextField()
        field.placeholderString = name
        field.font = colors.mono
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.stringValue = state.key
        field.setAccessibilityIdentifier("cmux.home.mcpConnect.key")
        let send: @MainActor () -> Void = { [state, actions] in
            let typed = field.stringValue
            guard !typed.isEmpty else { return }
            state.key = ""
            field.stringValue = ""
            actions.submitKey(McpConnectKey(typed))
        }
        let save = dialogButton(McpConnectStrings.save, id: "save", hint: .return, enabled: !state.key.isEmpty, action: send)
        field.delegate = state.hold(McpConnectKeyFieldDelegate(state: state, save: save, submit: send))
        var buttons: [NSView] = []
        if case .key(_, optional: true) = card.auth {
            buttons.append(plainButton(McpConnectStrings.skipKey) { [actions] in actions.submitKey(McpConnectKey("")) })
        }
        buttons += [spacer(), dialogButton(McpConnectStrings.cancel, id: "cancel", hint: .escape) { [actions] in actions.cancel() }, save]
        return column([field, label(McpConnectStrings.keyPrivate, font: colors.caption, color: colors.tertiary), row(buttons, spacing: 8)],
                      spacing: 6)
    }

    /// A waiting line with Cancel.
    private func phaseLine(_ text: String) -> NSView {
        let spinner = StatusIndicatorView.spinner()
        spinner.spin(true)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([spinner.widthAnchor.constraint(equalToConstant: 12), spinner.heightAnchor.constraint(equalToConstant: 12)])
        return row([spinner, label(text, font: colors.body, color: colors.secondary), spacer(),
                    plainButton(McpConnectStrings.cancel) { [actions] in actions.cancel() }], spacing: 8)
    }

    /// The connected result: the count line, and under it (when open) each tool with its class; a
    /// held tool says why.
    private func toolList(_ tools: [McpConnectCard.Tool]) -> NSView {
        let writes = tools.filter { $0.kind != .read }.count
        let disclosure = NSButton(title: "", target: nil, action: nil)
        disclosure.bezelStyle = .disclosure
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.state = state.toolsOpen ? .on : .off
        disclosure.target = state.hold(McpConnectButton { [state] in state.toolsOpen.toggle() })
        disclosure.action = #selector(McpConnectButton.run)
        disclosure.setAccessibilityIdentifier("cmux.home.mcpConnect.tools")
        let head = row([disclosure, iconLine(McpConnectStrings.connected(card.title, tools: tools.count, writes: writes),
                                             symbol: "checkmark.circle", font: colors.body, color: colors.text)], spacing: 4)
        guard state.toolsOpen else { return head }
        let list = column(tools.map { tool in
            var parts: [NSView] = [symbol(symbolName(tool), color: tool.flagged ? colors.danger : colors.tertiary),
                                   label(tool.name, font: colors.mono, color: colors.text)]
            if tool.flagged { parts.append(label(McpConnectStrings.flagged, font: colors.caption, color: colors.danger)) }
            return row(parts, spacing: 6)
        }, spacing: 2, fill: false)
        list.edgeInsets = NSEdgeInsets(top: 4, left: 20, bottom: 0, right: 0)
        return column([head, list], spacing: 0)
    }

    private func symbolName(_ tool: McpConnectCard.Tool) -> String {
        if tool.flagged { return "hand.raised" }
        switch tool.kind {
        case .read: return "eye"
        case .write: return "pencil"
        case .destructive: return "trash"
        }
    }
}

/// The access line: what signing in grants.
struct McpConnectAccessText {
    let card: McpConnectCard

    var text: String {
        switch card.auth {
        case .none: McpConnectStrings.noSignIn
        case .oauth(let scopes), .device(let scopes):
            scopes.isEmpty ? McpConnectStrings.signInWith(card.title)
                : scopes.joined(separator: ", ") + " · " + McpConnectStrings.signInWith(card.title)
        case .key(let name, _): McpConnectStrings.keyNamed(name)
        }
    }
}
