#if DEBUG
import AppKit
import CmuxNextDesign

/// DEBUG ONLY (Environment Secrets Playground), direction 2 "Sentences": one card per value in a
/// narrow column, each card says in plain words where its value can go; choices are large tiles.
struct EnvSentencesDirection {
    let model: EnvSecretsPlaygroundModel
    /// Called after any model change; the root rebuilds everything.
    let reload: @MainActor () -> Void

    private var sample: EnvSecretsSample { model.sample }

    /// The whole direction for ``EnvSecretsPlaygroundModel/scene``: a centred column, 680 points at most.
    func make() -> NSView {
        let state: NSView = switch model.scene {
        case .empty: empty()
        case .paste: paste()
        case .saved: cards(sample.saved) { savedFooter($0) }
        case .noHost: noHost()
        case .approval: cards(sample.saved) { approval($0) }
        case .audit: audit()
        case .revoke: cards(sample.saved) { revoke($0) }
        case .scopes: scopes()
        case .request: request()
        case .cli: EnvTerminalFrames().content()
        }
        let column = fullV([header(), state], spacing: 16)
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        column.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(column)
        let wide = column.widthAnchor.constraint(equalToConstant: 680)
        wide.priority = .defaultHigh
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: holder.topAnchor, constant: 26),
            column.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -26),
            column.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: 680),
            column.widthAnchor.constraint(lessThanOrEqualTo: holder.widthAnchor, constant: -60),
            wide,
        ])
        return envScroll(holder)
    }

    // MARK: Parts

    private func header() -> NSView {
        let pills: [NSView] = EnvSecretsEntry.Scope.allCases.map { scope in  // visible-only: the three scopes
            let on = model.scope == scope
            let ink: NSColor = on ? .controlAccentColor : EnvInk.secondary
            let pill = EnvBox(envIconLabel(scope.title, symbol: scope.symbol, size: TypeScale.detail, weight: .semibold, color: ink),
                              padding: envPad(h: 10, v: 4),
                              fill: on ? NSColor.controlAccentColor.withAlphaComponent(0.16) : .tertiarySystemFill, corner: .capsule)
            return EnvClickArea(pill) { model.scope = scope; reload() }
        }
        let row = envH(pills + [envSpacer(), EnvButton("Add", look: .prominent)], spacing: 6)
        return fullV([envLabel(sample.environment, size: TypeScale.heading, weight: .semibold),
                     envLabel("Values every chat in this environment starts with. Secrets stay out of the machine unless you say otherwise.",
                              size: TypeScale.body, color: EnvInk.secondary, wraps: true),
                     row], spacing: 10)
    }

    /// A vertical stack whose children take its full width; a one-line label in it stops hugging its text,
    /// so the column, not the text, sets the width.
    private func fullV(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        for case let label as NSTextField in views { label.setContentHuggingPriority(.defaultLow, for: .horizontal) }
        return envV(views, spacing: spacing, fill: true)
    }

    /// A choice tile's fill: the label colour at 3.5 %, as SwiftUI's `EnvInk.fill.opacity(0.7)`. Built per look
    /// because `withAlphaComponent` on a dynamic label colour resolves to white at that alpha in both looks.
    private var tileFill: NSColor {
        NSColor(name: nil) { look in
            (look.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor.white : NSColor.black).withAlphaComponent(0.035)  // colour-allow: a 3.5 % label-colour wash per look; withAlphaComponent on labelColor loses its hue
        }
    }

    /// `color` at `opacity` of its own alpha, resolved per look (SwiftUI's `.opacity`): a label colour's
    /// `withAlphaComponent` draws white in both looks, so the colour is resolved first, then faded.
    private func wash(_ color: NSColor, _ opacity: CGFloat) -> NSColor {
        NSColor(name: nil) { look in
            var resolved = color
            look.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) ?? color }
            return resolved.withAlphaComponent(resolved.alphaComponent * opacity)
        }
    }

    /// `view` at its own width on the left of a full-width row.
    private func lead(_ view: NSView) -> NSView { envH([view, envSpacer()], spacing: 0) }

    /// A rounded card the full width of the column; `highlight` draws its border in that colour, 1.5 points wide.
    private func card(_ views: [NSView], spacing: CGFloat = 8, highlight: NSColor? = nil) -> NSView {
        EnvBox(fullV(views, spacing: spacing), padding: envPad(14), fill: EnvInk.surface,
               border: highlight?.withAlphaComponent(0.6) ?? EnvInk.line, borderWidth: highlight == nil ? 1 : 1.5, corner: .radius(10))
    }

    private func title(_ entry: EnvSecretsEntry) -> NSView {
        envH([envLabel(entry.name, size: TypeScale.body, weight: .semibold, mono: true), envKindBadge(entry.kind), envSpacer(),
              envLabel(entry.shown, size: TypeScale.detail, color: EnvInk.secondary, mono: true)], spacing: 8)
    }

    private func sentence(_ entry: EnvSecretsEntry) -> NSView {
        envLabel(entry.sentence, size: TypeScale.body, color: EnvInk.text, wraps: true)
    }

    private func cards(_ rows: [EnvSecretsEntry], footer: (EnvSecretsEntry) -> NSView) -> NSView {
        let views: [NSView] = rows.map { entry in  // visible-only: a fixed sample of 6 saved values
            let stripe = entry.name == "STRIPE_SECRET_KEY"
            return card([title(entry), sentence(entry), stripe ? footer(entry) : envProvenance(entry)],
                        highlight: stripe ? .controlAccentColor : nil)
        }
        return fullV(views, spacing: 10)
    }

    private func hosts(_ entry: EnvSecretsEntry) -> [NSView] {
        entry.hosts.map { envHostChip($0) }  // visible-only: fixed sample list of at most 4 items
    }

    // MARK: States

    private func empty() -> NSView {
        let drop = envV([envSymbol("doc.on.clipboard", size: TypeScale.heading, color: EnvInk.tertiary),
                         envLabel("Paste or drop a .env file here", size: TypeScale.detail, color: EnvInk.secondary)],
                        spacing: 4, align: .centerX)
        let dropArea = NSView()
        dropArea.translatesAutoresizingMaskIntoConstraints = false
        drop.translatesAutoresizingMaskIntoConstraints = false
        dropArea.addSubview(drop)
        NSLayoutConstraint.activate([drop.centerXAnchor.constraint(equalTo: dropArea.centerXAnchor),
                                     drop.centerYAnchor.constraint(equalTo: dropArea.centerYAnchor)])
        let box = envSized(EnvBox(dropArea, border: EnvInk.line, corner: .radius(8), dash: [5, 4]), height: 96)
        let top = card([
            envLabel("Nothing here yet", size: TypeScale.title, weight: .semibold),
            envLabel("Paste your .env and cmux sorts each line: plain settings, keys for an API, keys for setup only. You check each one before anything is saved.",
                     size: TypeScale.body, color: EnvInk.secondary, wraps: true),
            box,
            envH([EnvButton("Paste .env", look: .prominent), EnvButton("Add one value"), envSpacer()]),
        ], spacing: 10)
        let kinds: [NSView] = [EnvSecretsKind.variable, .apiSecret, .setupSecret].map { kind in  // visible-only: three fixed types
            fullV([lead(envKindBadge(kind, long: true)),
                  envLabel(kind.promise, size: TypeScale.caption, color: EnvInk.secondary, wraps: true)], spacing: 4)
        }
        let row = envH(kinds, spacing: 10, align: .top)
        row.distribution = .fillEqually
        return fullV([top, EnvBox(row, padding: envPad(h: 4, v: 0))], spacing: 12)
    }

    private func paste() -> NSView {
        let rows: [NSView] = model.review.map { entry in  // visible-only: a fixed sample of 7 pasted lines
            var parts: [NSView] = [
                envH([envLabel(entry.name, size: TypeScale.body, weight: .semibold, mono: true), envSpacer(),
                      envKindMenu(model, entry, reload: reload)], spacing: 8),
                sentence(entry),
            ]
            if let reason = entry.reason {
                parts.append(envLabel("Picked because: " + String(reason.prefix(1)).lowercased() + String(reason.dropFirst()) + ".",
                                      size: TypeScale.caption, color: EnvInk.tertiary, wraps: true))
            }
            if entry.kind == .envSecret {
                parts.append(envNote(.warning, "The agent and any code it runs can read and print this. A team environment needs an admin to allow it."))
            }
            return card(parts, highlight: entry.kind == .envSecret ? EnvInk.warning : nil)
        }
        return fullV([envLabel("7 lines to check", size: TypeScale.title, weight: .semibold),
                     envLabel("cmux picked a type for each line from its name and value. Change any of them before you save.",
                              size: TypeScale.detail, color: EnvInk.secondary, wraps: true)]
                    + rows + [envH([envSpacer(), EnvButton("Cancel"), EnvButton("Save 7 values", look: .prominent)])],
                    spacing: 10)
    }

    private func savedFooter(_ entry: EnvSecretsEntry) -> NSView {
        // A destructive-role bordered button: a red-tinted bezel with a red title, not a solid red fill.
        let revoke = EnvButton("Revoke now", small: true)
        revoke.bezelColor = EnvInk.danger.withAlphaComponent(0.2)
        revoke.attributedTitle = NSAttributedString(string: "Revoke now", attributes: [
            .foregroundColor: EnvInk.danger, .font: NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small)),
        ])
        return fullV([
            envDivider(),
            envH(hosts(entry) + [envSpacer(), envProvenance(entry)], spacing: 4),
            envLabel("The value is write-only: cmux shows its last 4 characters and never the rest. There is no Reveal, Copy or Export.",
                     size: TypeScale.caption, color: EnvInk.tertiary, wraps: true),
            envH([EnvButton("Enter new value", small: true), EnvButton("Edit hosts", small: true), envSpacer(), revoke]),
        ], spacing: 8)
    }

    private func noHost() -> NSView {
        let entry = sample.noHost
        let tiles = [
            choice(kind: .apiSecret, title: "Add a host", body: "Name the API that needs it, for example api.example.com. It stays out of the machine.",
                   button: "Add host", primary: false),
            choice(kind: .setupSecret, title: "Use for setup only", body: "The setup script reads it, then cmux removes it before the agent starts.",
                   button: "Use for setup", primary: true),
            choice(kind: .envSecret, title: "Put in the environment", body: "The agent and any code it runs can read and print it. Use it only for tools that must.",
                   button: "Put in environment…", primary: false),
        ]
        let row = envH(tiles, spacing: 10, align: .top)
        row.distribution = .fillEqually
        return card([title(entry),
                     envLabel("No host yet, so no request can carry this secret. Choose how it is used:", size: TypeScale.body, wraps: true),
                     row], highlight: EnvInk.danger)
    }

    private func choice(kind: EnvSecretsKind, title: String, body: String, button: String, primary: Bool) -> NSView {
        let stack = fullV([lead(envSymbol(kind.symbol, size: TypeScale.title, color: kind.tint)),
                          envLabel(title, size: TypeScale.detail, weight: .semibold),
                          envLabel(body, size: TypeScale.caption, color: EnvInk.secondary, wraps: true),
                          envSpacer(minLength: 0),
                          lead(EnvButton(button, look: primary ? .prominent : .normal, small: true))], spacing: 6)
        let tile = EnvBox(stack, padding: envPad(10), fill: tileFill, corner: .radius(8))
        tile.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        return tile
    }

    private func approval(_ entry: EnvSecretsEntry) -> NSView {
        let steps = envH([step("Asked", "\(sample.pendingBy) · \(sample.pendingAt)", done: true),
                          step("Admin approves", "Touch ID on a Mac", done: false, current: true),
                          step("Applied", "Then chats may send to it", done: false)], spacing: 0, align: .top)
        steps.distribution = .fillEqually
        return fullV([
            envDivider(),
            envH(hosts(entry) + [envHostChip(sample.pendingHost, added: true), envSpacer()], spacing: 4),
            steps,
            envLabel("Nothing changes until an admin approves. Until then, the secret goes only to api.stripe.com.",
                     size: TypeScale.detail, color: EnvInk.secondary, wraps: true),
            envH([EnvButton("Approve with Touch ID", look: .prominent, symbol: "touchid", small: true),
                  EnvButton("Decline", small: true), envSpacer()]),
        ], spacing: 10)
    }

    private func step(_ title: String, _ caption: String, done: Bool, current: Bool = false) -> NSView {
        let symbol = envSymbol(done ? "checkmark.circle.fill" : current ? "circle.dotted.circle" : "circle", size: TypeScale.body,
                               color: done ? EnvInk.good : current ? EnvInk.warning : EnvInk.tertiary)
        let text = envV([envLabel(title, size: TypeScale.detail, weight: .semibold),
                         envLabel(caption, size: TypeScale.caption, color: EnvInk.secondary)], spacing: 1)
        return envH([symbol, text, envSpacer()], spacing: 6, align: .firstBaseline)
    }

    private func audit() -> NSView {
        let entry = sample.saved[0]
        let rows: [NSView] = sample.audit.map { event in  // visible-only: a fixed sample history of 7 lines
            let dot = envSized(EnvBox(envSymbol(event.outcome.symbol, size: TypeScale.caption, weight: .semibold, color: event.outcome.tint),
                                      fill: wash(event.outcome.tint, 0.12), corner: .capsule), width: 22, height: 22)
            var rail: [NSView] = [dot]
            if event.id != sample.audit.last?.id { rail.append(envSized(EnvBox(nil, fill: EnvInk.line), width: 1, height: 18)) }
            let text = envV([envLabel(line(event), size: TypeScale.detail),
                             envLabel(event.time, size: TypeScale.caption, color: EnvInk.secondary, digits: true)], spacing: 1)
            return envH([envV(rail, spacing: 0, align: .centerX), text, envSpacer()], spacing: 10, align: .top)
        }
        return card([title(entry), sentence(entry), envDivider(),
                     envLabel("History", size: TypeScale.body, weight: .semibold),
                     fullV(rows, spacing: 0),
                     envLabel("The value itself is never logged.", size: TypeScale.caption, color: EnvInk.tertiary)])
    }

    private func line(_ event: EnvSecretsAuditEvent) -> String {
        switch event.outcome {
        case .sent: "Sent to \(event.host) for “\(event.who)”"
        case .blocked: "Blocked a request to \(event.host) from “\(event.who)”: host not allowed"
        case .hostAdded: "\(event.who) asked to add \(event.host). Waiting for an admin."
        case .replaced: "\(event.who) entered a new value (\(event.detail.lowercased()))"
        case .created: "\(event.who) created it for \(event.host)"
        case .revoked: "\(event.who) revoked it"
        }
    }

    private func revoke(_ entry: EnvSecretsEntry) -> NSView {
        let chats: [NSView] = sample.runningChats.map { chat in  // visible-only: fixed sample list of at most 4 items
            envIconLabel(chat, symbol: "bubble.left", size: TypeScale.detail, color: EnvInk.secondary)
        }
        return fullV([
            envDivider(),
            envLabel("Revoke now?", size: TypeScale.title, weight: .semibold),
            envLabel("\(entry.name) stops working everywhere at once. These \(sample.runningChats.count) running chats lose it now:",
                     size: TypeScale.body, wraps: true),
            lead(envV(chats, spacing: 4)),
            envLabel("Requests to api.stripe.com fail until you enter a new value. The history keeps the revoke.",
                     size: TypeScale.detail, color: EnvInk.secondary, wraps: true),
            envH([envSpacer(), EnvButton("Keep it"), EnvButton("Revoke with Touch ID", look: .destructive, symbol: "touchid")]),
        ], spacing: 10)
    }

    private func scopes() -> NSView {
        var strip: [NSView] = []
        var tiles: [NSView] = []
        for scope in EnvSecretsEntry.Scope.allCases.reversed() {  // visible-only: the three scopes
            let tile = EnvBox(fullV([lead(envScopeTag(scope, strong: true)),
                                    envLabel(scope.caption, size: TypeScale.caption, color: EnvInk.secondary, wraps: true)],
                                   spacing: 4),
                              padding: envPad(10), fill: tileFill, corner: .radius(8))
            tile.heightAnchor.constraint(greaterThanOrEqualToConstant: 74).isActive = true
            tiles.append(tile)
            strip.append(tile)
            if scope != .team {
                strip.append(EnvBox(envSymbol("chevron.right", size: TypeScale.body, color: EnvInk.tertiary),
                                    padding: NSEdgeInsets(top: 28, left: 0, bottom: 0, right: 0)))
            }
        }
        let row = envH(strip, spacing: 8, align: .top)
        for tile in tiles.dropFirst() { tile.widthAnchor.constraint(equalTo: tiles[0].widthAnchor).isActive = true }
        let layers: [NSView] = sample.layers.map { layer in  // visible-only: a fixed sample of 6 names
            card([envH([envLabel(layer.name, size: TypeScale.body, weight: .semibold, mono: true), envKindBadge(layer.kind), envSpacer(),
                        envLabel(layer.value(layer.winner) ?? "", size: TypeScale.detail, mono: true)], spacing: 8),
                  envLabel(provenance(layer), size: TypeScale.detail, color: EnvInk.secondary, wraps: true)])
        }
        return fullV([row, envLabel("The first scope that sets a name wins.", size: TypeScale.detail, color: EnvInk.secondary)] + layers,
                    spacing: 12)
    }

    private func provenance(_ layer: EnvSecretsSample.Layer) -> String {
        let others = EnvSecretsEntry.Scope.allCases.filter { $0 != layer.winner && layer.value($0) != nil }
        let from = "From \(layer.winner.title)."
        guard !others.isEmpty else { return from }
        return from + " Overrides " + ListFormatter.localizedString(byJoining: others.map { "\($0.title) (\(layer.value($0) ?? ""))" }) + "."
    }

    private func request() -> NSView {
        let field = NSSecureTextField()
        field.focusRingType = .none
        field.placeholderString = "Type or paste the value"
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: TypeScale.field)
        field.translatesAutoresizingMaskIntoConstraints = false
        let promises = envV([
            promise("keyboard", "You type it here. The agent never sees it."),
            promise("curlybraces", "The agent gets $\(sample.requestName), a placeholder."),
            promise("arrow.up.right", "cmux adds the value only on requests to \(sample.requestHost)."),
            promise("eye.slash", "After you save, nobody can read it back: not you, not an agent."),
        ], spacing: 6)
        return card([
            envLabel("“\(sample.requestChat)” asks for a secret", size: TypeScale.title, weight: .semibold, wraps: true),
            envLabel("It wants \(sample.requestName), to send to \(sample.requestHost).", size: TypeScale.body, wraps: true),
            envLabel("“\(sample.requestReason)”", size: TypeScale.body, color: EnvInk.secondary, wraps: true),
            field,
            lead(promises),
            envDivider(),
            envLabel("Where to keep it", size: TypeScale.detail, weight: .semibold),
            envRequestScopePicker(model, reload: reload),
            envH([envSpacer(), EnvButton("Decline"), EnvButton(model.requestSaveTitle, look: .prominent)]),
        ], highlight: EnvSecretsKind.apiSecret.tint)
    }

    private func promise(_ symbol: String, _ text: String) -> NSView {
        envIconLabel(text, symbol: symbol, size: TypeScale.detail, color: EnvInk.text)
    }
}
#endif
