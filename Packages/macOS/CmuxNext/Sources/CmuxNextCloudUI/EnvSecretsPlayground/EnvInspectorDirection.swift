#if DEBUG
import AppKit
import CmuxNextDesign

/// DEBUG ONLY (Environment Secrets Playground), direction 3 "Inspector": a source list grouped by type
/// on the left, the selected value's form on the right, as a Mac settings pane; approvals, history
/// and revoke are sections and sheets of the detail, never inline in the list.
struct EnvInspectorDirection {
    let model: EnvSecretsPlaygroundModel
    /// Called after any model change; the root rebuilds everything.
    let reload: @MainActor () -> Void

    private var sample: EnvSecretsSample { model.sample }

    /// The whole direction for ``EnvSecretsPlaygroundModel/scene``.
    func make() -> NSView {
        if model.scene == .cli { return EnvTerminalFrames().make() }
        let side = sidebar()
        let line = envDivider(vertical: true)
        let pane = detail()
        pane.setContentHuggingPriority(.init(1), for: .horizontal)
        let split = envH([envSized(side, width: 260), line, pane], spacing: 0, align: .top)
        split.distribution = .fill
        for view in [side, line, pane] {  // visible-only: the three columns of the split
            view.heightAnchor.constraint(equalTo: split.heightAnchor).isActive = true
        }
        return split
    }

    // MARK: List

    private var rows: [EnvSecretsEntry] {
        switch model.scene {
        case .empty: []
        case .paste: model.review
        case .noHost: [sample.noHost] + sample.saved
        case .request: [EnvSecretsEntry(name: sample.requestName, kind: .apiSecret, hosts: [sample.requestHost])] + sample.saved
        default: sample.saved
        }
    }

    private var selected: String? {
        switch model.scene {
        case .empty: nil
        case .paste: "LEGACY_LICENSE"
        case .noHost: sample.noHost.name
        case .scopes: "REGION"
        case .request: model.sample.requestName
        default: "STRIPE_SECRET_KEY"
        }
    }

    private func sidebar() -> NSView {
        let scopes = EnvSecretsEntry.Scope.allCases
        let picker = EnvSegmented(scopes.map(\.title), selected: scopes.firstIndex(of: model.scope) ?? 0) { [model, reload] index in  // visible-only: the three scopes
            model.scope = scopes[index]
            reload()
        }
        let header = EnvBox(envV([envLabel(sample.environment, size: TypeScale.body, weight: .semibold), picker], spacing: 8, fill: true),
                            padding: envPad(12))
        var parts: [NSView] = [header, envDivider()]
        if model.scene == .scopes {
            parts += [scopeList(), envSpacer()]
        } else if rows.isEmpty {
            parts += [EnvBox(envLabel("No values", color: EnvInk.tertiary), padding: envPad(12)), envSpacer()]
        } else {
            let list = envV(group("Secrets", rows.filter { $0.kind != .variable }) + group("Variables", rows.filter { $0.kind == .variable }),
                            spacing: 1, fill: true)
            let scroll = envScroll(EnvBox(list, padding: NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)))
            scroll.setContentHuggingPriority(.init(1), for: .vertical)
            parts.append(scroll)
        }
        let add = barButton("plus", label: "Add value")  // plus-button-allow: a prototype glyph inside a DEBUG playground
        let paste = barButton("doc.on.clipboard", label: "Paste .env")
        parts += [envDivider(), EnvBox(envH([add, paste, envSpacer()], spacing: 2), padding: envPad(6))]
        return EnvBox(envV(parts, spacing: 0, fill: true), fill: EnvInk.canvas)
    }

    /// A 22-point icon button of the list's bottom bar.
    private func barButton(_ symbol: String, label: String) -> NSView {
        let area = EnvClickArea(fixedSymbol(symbol, size: TypeScale.body, color: EnvInk.text, width: 22, height: 22)) {}
        area.setAccessibilityLabel(label)
        area.setAccessibilityRole(.button)
        return area
    }

    private func group(_ title: String, _ entries: [EnvSecretsEntry]) -> [NSView] {
        guard !entries.isEmpty else { return [] }
        let heading = EnvBox(envLabel(title, size: TypeScale.caption, weight: .semibold, color: EnvInk.tertiary),
                             padding: NSEdgeInsets(top: 8, left: 14, bottom: 2, right: 14))
        return [heading] + entries.map { listRow($0, selected: $0.name == selected) }  // visible-only: a fixed sample list of at most 8 rows
    }

    private func listRow(_ entry: EnvSecretsEntry, selected: Bool) -> NSView {
        let ink = selected ? NSColor.white : EnvInk.text
        let text = envV([envLabel(entry.name, weight: .semibold, color: ink, mono: true),
                         envLabel(subtitle(entry), size: TypeScale.caption, color: selected ? NSColor.white.withAlphaComponent(0.8) : EnvInk.secondary)],
                        spacing: 1)
        var parts: [NSView] = [fixedSymbol(entry.kind.symbol, color: selected ? .white : entry.kind.tint, width: 16), text, envSpacer()]
        if marker(entry) {
            parts.append(envSized(EnvBox(nil, fill: selected ? .white : EnvInk.warning, corner: .capsule), width: 7, height: 7))
        }
        return selectable(envH(parts, spacing: 8), selected: selected, vertical: 5)
    }

    /// A list row's content with its padding and, when `selected`, the accent selection fill.
    private func selectable(_ content: NSView, selected: Bool, vertical: CGFloat) -> NSView {
        let pill = EnvBox(content, padding: envPad(h: 8, v: vertical), fill: selected ? .controlAccentColor : nil, corner: .radius(6))
        return EnvBox(pill, padding: NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6))
    }

    private func subtitle(_ entry: EnvSecretsEntry) -> String {
        if model.scene == .paste { return "Review · \(entry.kind.short)" }
        if model.scene == .approval, entry.name == "STRIPE_SECRET_KEY" { return "Host change waiting" }
        if model.scene == .noHost, entry.name == sample.noHost.name { return "Needs a host" }
        if model.scene == .request, entry.name == sample.requestName { return "Asked by an agent" }
        switch entry.kind {
        case .apiSecret: return entry.hosts.first ?? "No host"
        case .setupSecret: return "Setup only"
        case .envSecret: return "In the environment"
        case .variable: return entry.value
        }
    }

    private func marker(_ entry: EnvSecretsEntry) -> Bool {
        (model.scene == .approval && entry.name == "STRIPE_SECRET_KEY")
            || (model.scene == .noHost && entry.name == sample.noHost.name)
            || (model.scene == .paste && entry.kind == .envSecret)
            || (model.scene == .request && entry.name == sample.requestName)
    }

    private func scopeList() -> NSView {
        let items: [NSView] = sample.layers.map { layer in  // visible-only: a fixed sample of 6 layers
            let on = layer.name == selected
            let row = envH([fixedSymbol(layer.winner.symbol, size: TypeScale.caption, color: on ? .white : EnvInk.secondary, width: 16),
                            envLabel(layer.name, weight: .semibold, color: on ? .white : EnvInk.text, mono: true),
                            envSpacer(),
                            envLabel(layer.winner.title, size: TypeScale.caption, color: on ? NSColor.white.withAlphaComponent(0.8) : EnvInk.secondary)],
                           spacing: 8)
            return selectable(row, selected: on, vertical: 6)
        }
        return EnvBox(envV(items, spacing: 1, fill: true), padding: NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0))
    }

    // MARK: Detail

    private func detail() -> NSView {
        switch model.scene {
        case .empty: emptyDetail()
        case .paste: pasteDetail()
        case .saved: form(sample.saved[0], tab: 0)
        case .noHost: noHostDetail()
        case .approval: form(sample.saved[0], tab: 0, pending: true)
        case .audit: form(sample.saved[0], tab: 1)
        case .revoke: withSheet(form(sample.saved[0], tab: 0), revokeSheet())
        case .scopes: scopesDetail()
        case .request: requestDetail()
        case .cli: EnvTerminalFrames().make()
        }
    }

    /// `page` with `sheet` laid over it, centred 24 points from the top.
    private func withSheet(_ page: NSView, _ sheet: NSView) -> NSView {
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        page.translatesAutoresizingMaskIntoConstraints = false
        sheet.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(page)
        holder.addSubview(sheet)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: holder.topAnchor), page.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: holder.trailingAnchor), page.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            sheet.topAnchor.constraint(equalTo: holder.topAnchor, constant: 24), sheet.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
        ])
        return holder
    }

    /// A scrolling detail page: `views` stacked 16 points apart, 20 points in from the edges.
    private func page(_ views: [NSView]) -> NSView {
        envScroll(EnvBox(envV(views, spacing: 16, fill: true), padding: envPad(20)))
    }

    /// `views` on one line at their own widths, left-aligned in the full width.
    private func leading(_ views: [NSView], spacing: CGFloat = 8) -> NSView {
        envH(views + [envSpacer()], spacing: spacing)
    }

    private func emptyDetail() -> NSView {
        let text = envLabel("Paste a .env file to start. You check every line and its type before cmux saves anything.",
                            color: EnvInk.secondary, wraps: true)
        text.alignment = .center
        let column = envV([envSymbol("key.horizontal", size: TypeScale.heading, color: EnvInk.tertiary),
                           envLabel("No values in \(sample.environment)", size: TypeScale.title, weight: .semibold),
                           envSized(text, width: 340),
                           envH([EnvButton("Paste .env", look: .prominent), EnvButton("Add value")])],
                          spacing: 12, align: .centerX)
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        column.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(column)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: holder.centerXAnchor), column.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
        ])
        return holder
    }

    /// A titled group: a caption over a bordered box whose rows are 10 points apart and full width.
    private func section(_ title: String, _ views: [NSView]) -> NSView {
        let box = EnvBox(envV(views, spacing: 10, fill: true), padding: envPad(12), fill: EnvInk.surface, border: EnvInk.line, corner: .radius(8))
        return envV([envLabel(title, size: TypeScale.caption, weight: .semibold, color: EnvInk.secondary), box], spacing: 8, fill: true)
    }

    /// A form row: a right-aligned 90-point label, then `content` on the label's baseline (or centred, for a
    /// chip or a field, which have no text baseline the stack can read).
    private func field(_ label: String, _ content: [NSView], align: NSLayoutConstraint.Attribute = .firstBaseline) -> NSView {
        let title = envLabel(label, color: EnvInk.secondary)
        title.alignment = .right
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return envH([envSized(title, width: 90)] + content + [envSpacer()], spacing: 12, align: align)
    }

    /// An SF Symbol centred in a fixed frame.
    private func fixedSymbol(_ name: String, size: CGFloat = TypeScale.detail, color: NSColor, width: CGFloat, height: CGFloat? = nil) -> NSView {
        let icon = envSymbol(name, size: size, color: color)
        icon.setContentHuggingPriority(.defaultLow, for: .horizontal)
        icon.setContentHuggingPriority(.defaultLow, for: .vertical)
        icon.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return envSized(icon, width: width, height: height)
    }

    /// A 34-point icon tile: the symbol in `tint` on a light wash of it.
    private func iconTile(_ symbol: String, tint: NSColor) -> NSView {
        envSized(EnvBox(fixedSymbol(symbol, size: TypeScale.heading, color: tint, width: 34, height: 34),
                        fill: tint.withAlphaComponent(0.14), corner: .radius(8)), width: 34, height: 34)
    }

    private func detailHeader(_ entry: EnvSecretsEntry) -> NSView {
        let text = envV([envLabel(entry.name, size: TypeScale.title, weight: .semibold, mono: true),
                         envLabel(entry.kind.title, color: EnvInk.secondary)], spacing: 2)
        return envH([iconTile(entry.kind.symbol, tint: entry.kind.tint), text, envSpacer()], spacing: 10)
    }

    private func typeRadio(_ current: EnvSecretsKind, entry: EnvSecretsEntry?) -> NSView {
        let items: [NSView] = EnvSecretsKind.allCases.map { kind in  // visible-only: the four row types
            let on = kind == current
            let title = envLabel(kind.title, weight: .semibold, color: EnvInk.text)
            title.setContentHuggingPriority(.defaultLow, for: .horizontal)
            // The note takes the row's width and wraps in a narrow window, as a SwiftUI Text does.
            let text = envV([title, envLabel(kind.promise, size: TypeScale.caption, color: EnvInk.secondary, wraps: true)], spacing: 1, fill: true)
            text.setContentHuggingPriority(.defaultLow, for: .horizontal)
            return EnvClickArea(envRadioRow(picked: on, title: title, text: text, size: TypeScale.body)) { [model, reload] in
                if let entry { model.setKind(kind, for: entry) }
                reload()
            }
        }
        return envV(items, spacing: 6, fill: true)
    }

    private func pasteDetail() -> NSView {
        let entry = model.review.first { $0.name == "LEGACY_LICENSE" } ?? model.review[0]
        var typeRows = [typeRadio(entry.kind, entry: entry)]
        if let reason = entry.reason {
            typeRows.append(envLabel("Picked because: \(reason).", size: TypeScale.caption, color: EnvInk.tertiary, wraps: true))
        }
        var views: [NSView] = [
            envH([envLabel("Review 7 pasted lines", size: TypeScale.title, weight: .semibold), envSpacer(),
                  envLabel("1 of 7 needs care", size: TypeScale.caption, color: EnvInk.warning)]),
            detailHeader(entry),
            section("Type", typeRows),
        ]
        if entry.kind == .envSecret {
            views.append(envNote(.warning, "The agent and any code it runs can read and print this value. cmux masks it in the terminal and the transcript as •••• (\(entry.name)). A team environment needs an admin to allow it."))
        }
        views.append(envH([EnvButton("Previous"), EnvButton("Next"), envSpacer(), EnvButton("Cancel"), EnvButton("Save 7 values", look: .prominent)]))
        return page(views)
    }

    /// The Details and History tabs, centred in 200 points as the original's fixed frame.
    private func tabs(_ tab: Int) -> NSView {
        let (left, right) = (envSpacer(), envSpacer())
        let row = envH([left, EnvSegmented(["Details", "History"], selected: tab), right], spacing: 0)
        left.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        return leading([envSized(row, width: 200)])
    }

    private func form(_ entry: EnvSecretsEntry, tab: Int, pending: Bool = false) -> NSView {
        var views: [NSView] = [detailHeader(entry), tabs(tab)]
        if tab == 1 {
            views.append(section("Every use and change", [
                leading([envAuditTable(sample.audit)]),
                envLabel("The value itself is never logged.", size: TypeScale.caption, color: EnvInk.tertiary),
            ]))
        } else {
            if pending { views.append(leading([pendingSection(entry)])) }
            views.append(section("Value", [
                field("Value", [envLabel("•••• \(entry.last4)", mono: true), EnvButton("Enter new value…", small: true)]),
                field("", [envLabel("Write-only. Nobody can read it back, not even an admin: there is no Reveal, Copy or Export.",
                                    size: TypeScale.caption, color: EnvInk.tertiary)]),
                field("Set by", [envProvenance(entry)]),
            ]))
            views.append(section("Where it goes", [
                field("Hosts", [envH(entry.hosts.map { envHostChip($0) }, spacing: 4)], align: .centerY),  // visible-only: fixed sample list of at most 4 items
                field("Sent as", [deliveryMenu(entry)]),
                field("", [envLabel(EnvSecretsKind.apiSecret.promise, size: TypeScale.caption, color: EnvInk.secondary)]),
            ]))
            let revoke = EnvButton("Revoke now…")
            revoke.hasDestructiveAction = true
            revoke.contentTintColor = EnvInk.danger
            revoke.attributedTitle = NSAttributedString(string: revoke.title, attributes: [
                .foregroundColor: EnvInk.danger, .font: revoke.font ?? NSFont.systemFont(ofSize: TypeScale.body),
            ])
            views.append(envH([envSpacer(), revoke]))
        }
        return page(views)
    }

    /// The "Sent as" menu: the entry's delivery as the title, the delivery choices as items.
    private func deliveryMenu(_ entry: EnvSecretsEntry) -> NSView {
        let menu = NSPopUpButton(frame: .zero, pullsDown: true)
        menu.addItem(withTitle: entry.delivery?.title ?? "")
        for choice in EnvSecretsEntry.Delivery.choices {  // visible-only: fixed sample list of at most 4 items
            menu.menu?.addItem(EnvMenuAction.item(choice.title) {})
        }
        menu.translatesAutoresizingMaskIntoConstraints = false
        menu.setContentHuggingPriority(.required, for: .horizontal)
        return menu
    }

    private func pendingSection(_ entry: EnvSecretsEntry) -> NSView {
        let title = envH([envSymbol("touchid", size: TypeScale.heading, color: EnvInk.warning),
                          envV([envLabel("Host change waiting for an admin", size: TypeScale.body, weight: .semibold),
                                envLabel("\(sample.pendingBy) asked to add \(sample.pendingHost) · \(sample.pendingAt)", color: EnvInk.secondary)],
                               spacing: 2)],
                         spacing: 8)
        let chips = envH(entry.hosts.map { envHostChip($0) } + [envHostChip(sample.pendingHost, added: true)], spacing: 4)  // visible-only: fixed sample list of at most 4 items
        let column = envV([title, chips,
                           envLabel("Until an admin approves on a Mac with Touch ID, the secret goes only to api.stripe.com.",
                                    size: TypeScale.caption, color: EnvInk.secondary),
                           envH([EnvButton("Approve with Touch ID", look: .prominent, symbol: "touchid", small: true),
                                 EnvButton("Decline", small: true)])],
                          spacing: 10)
        return EnvBox(column, padding: envPad(12), fill: EnvInk.warning.withAlphaComponent(0.08),
                      border: EnvInk.warning.withAlphaComponent(0.45), corner: .radius(8))
    }

    private func noHostDetail() -> NSView {
        let entry = sample.noHost
        let host = NSTextField(string: "")
        host.focusRingType = .none
        host.placeholderString = "api.example.com"
        host.isBezeled = true
        host.bezelStyle = .roundedBezel
        host.font = .monospacedSystemFont(ofSize: TypeScale.body, weight: .regular)
        return page([
            detailHeader(entry),
            envNote(.danger, "This API secret has no host, so no request can carry it. Add a host, or choose another type."),
            section("Where it goes", [field("Hosts", [envSized(host, width: 240)], align: .centerY)]),
            section("Or use it another way", [
                leading([EnvButton("Use for setup only", look: .prominent, symbol: EnvSecretsKind.setupSecret.symbol)]),
                envLabel(EnvSecretsKind.setupSecret.promise, size: TypeScale.caption, color: EnvInk.secondary),
                envDivider(),
                leading([EnvButton("Put in the environment…", symbol: EnvSecretsKind.envSecret.symbol)]),
                envLabel(EnvSecretsKind.envSecret.promise, size: TypeScale.caption, color: EnvInk.warning),
            ]),
        ])
    }

    private func revokeSheet() -> NSView {
        let column = envV([
            leading([envSymbol("xmark.octagon.fill", size: TypeScale.heading, color: EnvInk.danger)]),
            envLabel("Revoke STRIPE_SECRET_KEY now?", size: TypeScale.field, weight: .semibold),
            envLabel("It stops everywhere at once. \(sample.runningChats.count) running chats lose it now. Requests to api.stripe.com fail until you enter a new value.",
                     color: EnvInk.secondary, wraps: true),
            envH([envSpacer(), EnvButton("Cancel"), EnvButton("Revoke with Touch ID", look: .destructive, symbol: "touchid")]),
        ], spacing: 10, fill: true)
        let sheet = EnvBox(column, padding: envPad(18), fill: EnvInk.canvas, border: EnvInk.line, corner: .radius(12))
        // Two shadows under the sheet's shape, as the SwiftUI sheet had: a tight contact shadow and a soft drop.
        let holder = envSized(NSView(), width: 380)
        for (alpha, blur, drop) in [(0.18, 18.0, 8.0), (0.10, 2.0, 1.0)] {  // visible-only: the two shadow layers
            let shape = EnvBox(nil, fill: EnvInk.canvas, corner: .radius(12))
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.shadowColor.withAlphaComponent(alpha)
            shadow.shadowBlurRadius = blur
            shadow.shadowOffset = NSSize(width: 0, height: -drop)
            shape.shadow = shadow
            pin(shape, in: holder)
        }
        pin(sheet, in: holder)
        return holder
    }

    /// Adds `view` to `holder`, edge to edge.
    private func pin(_ view: NSView, in holder: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: holder.topAnchor), view.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: holder.leadingAnchor), view.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
        ])
    }

    private func scopesDetail() -> NSView {
        let layer = sample.layers.first { $0.name == "REGION" } ?? sample.layers[0]
        let log = sample.layers.first { $0.name == "LOG_LEVEL" } ?? sample.layers[0]
        return page([
            envLabel("Where each value comes from", size: TypeScale.title, weight: .semibold),
            envLabel("Chat wins over Personal, Personal wins over Team. Personal values never apply when a teammate drives your chat.",
                     color: EnvInk.secondary, wraps: true),
            stack(layer),
            stack(log),
        ])
    }

    private func stack(_ layer: EnvSecretsSample.Layer) -> NSView {
        var views: [NSView] = []
        for scope in EnvSecretsEntry.Scope.allCases.reversed() {  // visible-only: the three scopes
            let won = scope == layer.winner
            let value: NSView = if let text = layer.value(scope) {
                envLabel(text, color: won ? EnvInk.text : EnvInk.tertiary, mono: true, strike: !won)
            } else {
                envLabel("Not set", color: EnvInk.tertiary)
            }
            var parts: [NSView] = [envSized(envScopeTag(scope, strong: won), width: 90), value, envSpacer()]
            if won {
                parts.append(EnvBox(envLabel("Used", size: TypeScale.caption, weight: .semibold, color: .controlAccentColor),
                                    padding: NSEdgeInsets(top: 1, left: 6, bottom: 1, right: 6),
                                    fill: NSColor.controlAccentColor.withAlphaComponent(0.14), corner: .capsule))
            }
            views.append(envH(parts, spacing: 10))
            views.append(EnvBox(envLabel(scope.caption, size: TypeScale.caption, color: EnvInk.tertiary),
                                padding: NSEdgeInsets(top: 0, left: 100, bottom: 0, right: 0)))
        }
        return section(layer.name, views)
    }

    private func requestDetail() -> NSView {
        let value = NSSecureTextField(string: "")
        value.focusRingType = .none
        value.placeholderString = "Type or paste the value"
        value.isBezeled = true
        value.bezelStyle = .roundedBezel
        let header = envH([iconTile("lock.shield", tint: EnvSecretsKind.apiSecret.tint),
                           envV([envLabel(sample.requestName, size: TypeScale.title, weight: .semibold, mono: true),
                                 envLabel("Asked by an agent in “\(sample.requestChat)”", color: EnvInk.secondary)], spacing: 2),
                           envSpacer()],
                          spacing: 10)
        return page([
            header,
            section("Request", [
                field("Why", [envLabel(sample.requestReason)]),
                field("Hosts", [envHostChip(sample.requestHost)], align: .centerY),
                field("Sent as", [envLabel("Authorization: Bearer", mono: true)]),
            ]),
            section("Value", [
                field("Value", [envSized(value, width: 300)], align: .centerY),
                field("", [envLabel("Only you can fill this. The agent gets the placeholder $\(sample.requestName) and never the value.",
                                    size: TypeScale.caption, color: EnvInk.secondary)]),
            ]),
            section("Where to keep it", [envRequestScopePicker(model, reload: reload)]),
            envH([envSpacer(), EnvButton("Decline"), EnvButton(model.requestSaveTitle, look: .prominent)]),
        ])
    }
}
#endif
