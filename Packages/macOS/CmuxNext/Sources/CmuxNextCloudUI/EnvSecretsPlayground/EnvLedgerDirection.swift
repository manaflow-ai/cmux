#if DEBUG
import AppKit
import CmuxNextDesign

/// DEBUG ONLY (Environment Secrets Playground), direction 1 "Ledger": a dense table, one line per
/// value, and a row's details, approval, history or revoke open in place under it.
struct EnvLedgerDirection {
    let model: EnvSecretsPlaygroundModel
    let reload: @MainActor () -> Void

    private var sample: EnvSecretsSample { model.sample }

    /// The header and the state the model picks, padded, top to bottom.
    func make() -> NSView {
        let content: NSView = switch model.scene {
        case .empty: empty()
        case .paste: paste()
        case .saved: table(sample.saved, open: "STRIPE_SECRET_KEY") { details($0) }
        case .noHost: noHost()
        case .approval: table(sample.saved, open: "STRIPE_SECRET_KEY") { approval($0) }
        case .audit: table(sample.saved, open: "STRIPE_SECRET_KEY") { _ in history() }
        case .revoke: table(sample.saved, open: "STRIPE_SECRET_KEY") { revoke($0) }
        case .scopes: scopes()
        case .request: request()
        case .cli: EnvTerminalFrames().make()
        }
        content.setContentHuggingPriority(.init(2), for: .vertical)
        let views: [NSView] = model.scene == .cli ? [header(), content] : [header(), content, envSpacer()]
        let column = envV(views, spacing: 14, fill: true)
        return EnvBox(column, padding: envPad(22))
    }

    // MARK: Parts

    private func header() -> NSView {
        let titles = envV([envLabel("Environment variables", size: TypeScale.title, weight: .semibold),
                           envLabel("\(sample.environment) · \(sample.team) team", color: EnvInk.secondary)], spacing: 2)
        let scopes = EnvSecretsEntry.Scope.allCases
        let picker = envSized(EnvSegmented(scopes.map(\.title), selected: scopes.firstIndex(of: model.scope) ?? 0) { [model, reload] index in  // visible-only: the three scopes
            model.scope = scopes[index]
            reload()
        }, width: 230)
        return envH([titles, envSpacer(), picker, EnvButton("Paste .env"), EnvButton("Add variable", look: .prominent)],
                    spacing: 12, align: .firstBaseline)
    }

    /// `view` at the leading edge of a cell `width` wide, or of the room left when `width` is nil.
    private func cell(_ view: NSView, _ width: CGFloat?) -> NSView {
        let row = envH([view, envSpacer()], spacing: 0)
        if let width { envSized(row, width: width) }
        return row
    }

    /// A table's column titles: caption, semibold, tertiary.
    private func titles(_ columns: [(String, CGFloat?)]) -> NSView {
        let cells = columns.map { cell(envLabel($0.0, size: TypeScale.caption, weight: .semibold, color: EnvInk.tertiary), $0.1) }  // visible-only: a fixed list of at most 5 column titles
        return EnvBox(envH(cells, spacing: 0), padding: envPad(h: 12, v: 6))
    }

    private func columns() -> NSView {
        titles([("Name", 210), ("Type", 130), ("Value", 120), ("Goes to", nil), ("Changed", 150)])
    }

    /// The fill under an open row and its detail: the SwiftUI fill (quaternary label at half) at 60 percent.
    private var openFill: NSColor { quaternary(0.5 * 0.6) }

    /// The quaternary label colour with its own alpha scaled by `factor` (`withAlphaComponent` replaces the
    /// alpha, so `EnvInk.fill` is far stronger than the SwiftUI `.opacity(0.5)` it stands for).
    private func quaternary(_ factor: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            var resolved = NSColor.quaternaryLabelColor
            appearance.performAsCurrentDrawingAppearance {
                let base = NSColor.quaternaryLabelColor.usingColorSpace(.sRGB) ?? NSColor.quaternaryLabelColor
                resolved = base.withAlphaComponent(base.alphaComponent * factor)
            }
            return resolved
        }
    }

    /// A table card: surface fill, hairline border, 8 pt corners, clipped.
    private func card(_ rows: [NSView], clip: Bool = true) -> NSView {
        let box = EnvBox(envV(rows, spacing: 0, fill: true), fill: EnvInk.surface, border: EnvInk.line, corner: .radius(8))
        if clip {
            box.wantsLayer = true
            box.layer?.cornerRadius = 8
            box.layer?.masksToBounds = true
        }
        return box
    }

    private func line(_ entry: EnvSecretsEntry, open: Bool) -> NSView {
        let chevron = cell(envSymbol(open ? "chevron.down" : "chevron.right", size: TypeScale.caption, weight: .semibold, color: EnvInk.tertiary), 10)
        let name = envH([chevron, envLabel(entry.name, weight: .semibold, mono: true)], spacing: 6)
        let row = envH([
            cell(name, 210),
            cell(envKindBadge(entry.kind), 130),
            cell(envLabel(entry.shown, color: entry.kind == .variable ? EnvInk.text : EnvInk.secondary, mono: true), 120),
            cell(goesTo(entry), nil),
            cell(envLabel(entry.setAt, size: TypeScale.caption, color: EnvInk.secondary, digits: true), 150),
        ], spacing: 0)
        return EnvBox(row, padding: envPad(h: 12, v: 8), fill: open ? openFill : nil)
    }

    private func chips(_ hosts: [String]) -> [NSView] {
        hosts.map { envHostChip($0) }  // visible-only: fixed sample list of at most 4 items
    }

    private func goesTo(_ entry: EnvSecretsEntry) -> NSView {
        switch entry.kind {
        case .apiSecret: envH(chips(entry.hosts), spacing: 4)
        case .setupSecret: envLabel("Setup script only", color: EnvInk.secondary)
        case .envSecret: envLabel("Every process in the machine", color: EnvInk.warning)
        case .variable: envLabel("Every process in the machine", color: EnvInk.secondary)
        }
    }

    private func table(_ rows: [EnvSecretsEntry], open: String, detail: (EnvSecretsEntry) -> NSView) -> NSView {
        var views: [NSView] = [columns(), envDivider()]
        for entry in rows {  // visible-only: a fixed sample of 6 rows
            views.append(line(entry, open: entry.name == open))
            if entry.name == open {
                views.append(EnvBox(detail(entry), padding: NSEdgeInsets(top: 12, left: 28, bottom: 12, right: 12), fill: openFill))
            }
            views.append(envDivider())
        }
        return card(views)
    }

    // MARK: States

    private func empty() -> NSView {
        let buttons = envH([EnvButton("Paste .env", look: .prominent), EnvButton("Add variable")])
        let text = envLabel("Paste a .env file or add one variable. Secret values are write-only after you save.", color: EnvInk.secondary)
        let center = envV([
            envSymbol("key.horizontal", size: TypeScale.heading, color: EnvInk.tertiary),
            envLabel("No variables in \(sample.environment) yet", size: TypeScale.field, weight: .semibold),
            text, buttons,
        ], spacing: 10, align: .centerX)
        center.setCustomSpacing(14, after: text)
        return card([columns(), envDivider(), EnvBox(center, padding: envPad(h: 0, v: 56))], clip: false)
    }

    private func paste() -> NSView {
        let top = envH([envIconLabel("Pasted 7 lines. Check each type, then save.", symbol: "doc.on.clipboard", weight: .semibold),
                        envSpacer(),
                        envLabel("4 secrets · 2 variables · 1 needs care", size: TypeScale.caption, color: EnvInk.secondary)])
        var rows: [NSView] = [titles([("Name", 190), ("Type", 170), ("Goes to", 230), ("Why this type", nil)]), envDivider()]
        for entry in model.review {  // visible-only: a fixed sample of 7 pasted lines
            let reason = envLabel(entry.reason ?? "", size: TypeScale.caption, color: EnvInk.secondary, wraps: true)
            reason.maximumNumberOfLines = 2
            let row = envH([
                cell(envLabel(entry.name, weight: .semibold, mono: true), 190),
                cell(envKindMenu(model, entry, reload: reload), 170),
                cell(reviewTarget(entry), 230),
                reason,
            ], spacing: 0)
            rows.append(EnvBox(row, padding: envPad(h: 12, v: 7)))
            if entry.kind == .envSecret {
                let note = envNote(.warning, "The agent and any code it runs can read and print LEGACY_LICENSE. cmux masks it in the terminal and the transcript. Team environments need an admin to allow this type.")
                rows.append(EnvBox(note, padding: NSEdgeInsets(top: 0, left: 12, bottom: 8, right: 12)))
            }
            rows.append(envDivider())
        }
        let bottom = envH([envLabel("Secret values are write-only after you save. Only the last 4 characters stay visible.",
                                    size: TypeScale.caption, color: EnvInk.secondary),
                           envSpacer(), EnvButton("Cancel"), EnvButton("Save 7 values", look: .prominent)])
        return envV([top, card(rows, clip: false), bottom], spacing: 10, fill: true)
    }

    private func reviewTarget(_ entry: EnvSecretsEntry) -> NSView {
        switch entry.kind {
        case .apiSecret:
            let delivery = envLabel(entry.delivery?.title ?? "", size: TypeScale.caption, color: EnvInk.tertiary)
            delivery.setContentCompressionResistancePriority(.init(100), for: .horizontal)
            return envH(chips(entry.hosts) + [delivery], spacing: 4)
        case .setupSecret: return envLabel("Setup script, then removed", color: EnvInk.secondary)
        case .envSecret: return envLabel("Machine environment", color: EnvInk.warning)
        case .variable: return envLabel(entry.value, mono: true)
        }
    }

    private func details(_ entry: EnvSecretsEntry) -> NSView {
        let key: (String) -> NSView = { envLabel($0, color: EnvInk.secondary) }
        let grid = envGrid([
            [key("Value"), envH([envLabel("•••• \(entry.last4)", mono: true),
                                 envLabel("Write-only. There is no Reveal, Copy or Export, for you or for an agent.",
                                          size: TypeScale.caption, color: EnvInk.tertiary)], spacing: 8, align: .firstBaseline)],
            [key("Hosts"), envH(chips(entry.hosts), spacing: 4)],
            [key("Sent as"), envLabel(entry.delivery?.title ?? "", mono: true)],
            [key("Set by"), envProvenance(entry)],
        ], columnSpacing: 18, rowSpacing: 8)
        let hostsRow = grid.row(at: 1)
        hostsRow.rowAlignment = .none
        hostsRow.yPlacement = .center
        let revoke = EnvButton("Revoke now", small: true)
        revoke.hasDestructiveAction = true
        revoke.bezelColor = EnvInk.danger.withAlphaComponent(0.18)
        revoke.attributedTitle = NSAttributedString(string: "Revoke now", attributes: [
            .foregroundColor: EnvInk.danger, .font: NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small)),
        ])
        let buttons = envH([EnvButton("Enter new value…", small: true), EnvButton("Edit hosts…", small: true),
                            EnvButton("History", small: true), envSpacer(), revoke])
        return envV([envH([grid, envSpacer()]), buttons], spacing: 10, fill: true)
    }

    private func noHost() -> NSView {
        let entry = sample.noHost
        let field = NSTextField()
        field.focusRingType = .none
        field.placeholderString = "api.example.com"
        field.bezelStyle = .roundedBezel
        field.controlSize = .small
        field.font = .monospacedSystemFont(ofSize: TypeScale.body, weight: .regular)
        let add = envH([envLabel("Add a host", color: EnvInk.secondary), envSized(field, width: 220),
                        envLabel("or", color: EnvInk.tertiary),
                        EnvButton("Use for setup only", look: .prominent, small: true),
                        EnvButton("Put in the environment…", small: true), envSpacer()], spacing: 8)
        let detail = envV([
            envNote(.danger, "An API secret needs at least one host. With no host, no request can carry it."),
            add,
            envLabel("Put in the environment lets the agent read the value. Use it only for tools that must read it themselves.",
                     size: TypeScale.caption, color: EnvInk.secondary),
        ], spacing: 10, fill: true)
        var views: [NSView] = [columns(), envDivider(), line(entry, open: true),
                               EnvBox(detail, padding: NSEdgeInsets(top: 12, left: 28, bottom: 12, right: 12), fill: openFill),
                               envDivider()]
        for other in sample.saved.prefix(3) {  // visible-only: the first 3 sample rows
            views.append(line(other, open: false))
            views.append(envDivider())
        }
        return card(views)
    }

    private func approval(_ entry: EnvSecretsEntry) -> NSView {
        let asked = envH([envSymbol("clock.badge.exclamationmark", size: TypeScale.body, color: EnvInk.warning),
                          envLabel("\(sample.pendingBy) asked to add a host · \(sample.pendingAt)", weight: .semibold), envSpacer()], spacing: 8)
        let hosts = envH([cell(envLabel("Hosts", color: EnvInk.secondary), 60)] + chips(entry.hosts)
            + [envHostChip(sample.pendingHost, added: true), envSpacer()], spacing: 4)
        let buttons = envH([EnvButton("Approve with Touch ID", look: .prominent, symbol: "touchid", small: true),
                            EnvButton("Decline", small: true), envSpacer(),
                            envLabel("Only admins see these buttons", size: TypeScale.caption, color: EnvInk.tertiary)])
        return envV([asked, hosts,
                     envLabel("Until an admin approves, the secret goes only to api.stripe.com. Every host change is in the history.",
                              size: TypeScale.caption, color: EnvInk.secondary),
                     buttons], spacing: 10, fill: true)
    }

    private func history() -> NSView {
        envV([envH([envAuditTable(sample.audit), envSpacer()]),
              envLabel("Each use and each change is listed. The value itself is never logged.",
                       size: TypeScale.caption, color: EnvInk.secondary)], spacing: 10)
    }

    private func revoke(_ entry: EnvSecretsEntry) -> NSView {
        let chats: [NSView] = sample.runningChats.map { chat in  // visible-only: fixed sample list of at most 4 items
            EnvBox(envIconLabel(chat, symbol: "bubble.left", size: TypeScale.caption, color: EnvInk.secondary),
                   padding: envPad(h: 6, v: 2), fill: quaternary(0.5), corner: .capsule)
        }
        let column = envV([
            envLabel("Revoke \(entry.name) now?", size: TypeScale.body, weight: .semibold),
            envLabel("It stops everywhere at once. \(sample.runningChats.count) running chats lose it now, and requests to api.stripe.com fail until you enter a new value.",
                     color: EnvInk.secondary),
            envH(chats + [envSpacer()], spacing: 6),
            envH([EnvButton("Cancel", small: true), EnvButton("Revoke with Touch ID", look: .destructive, symbol: "touchid", small: true)]),
        ], spacing: 10)
        let box = EnvBox(column, padding: envPad(12), border: EnvInk.danger.withAlphaComponent(0.5), corner: .radius(6))
        return envH([box, envSpacer()], spacing: 0)
    }

    private func scopes() -> NSView {
        var rows: [NSView] = [titles([("Name", 210), ("Used value", 150), ("From", 110), ("Also set in", nil)]), envDivider()]
        for layer in sample.layers {  // visible-only: a fixed sample of 6 layers
            let others: [NSView] = EnvSecretsEntry.Scope.allCases.filter { $0 != layer.winner && layer.value($0) != nil }.map { scope in  // visible-only: at most the two other scopes
                envH([envScopeTag(scope),
                      envLabel(layer.value(scope) ?? "", size: TypeScale.caption, color: EnvInk.tertiary, mono: true, strike: true)], spacing: 4)
            }
            let row = envH([
                cell(envLabel(layer.name, weight: .semibold, mono: true), 210),
                cell(envLabel(layer.value(layer.winner) ?? "", mono: true), 150),
                cell(envScopeTag(layer.winner, strong: true), 110),
                cell(envH(others, spacing: 10), nil),
            ], spacing: 0)
            rows.append(EnvBox(row, padding: envPad(h: 12, v: 8)))
            rows.append(envDivider())
        }
        return envV([envNote(.info, "Most specific wins: Chat, then Personal, then Team. Personal values never apply when a teammate drives your chat."),
                     card(rows, clip: false)], spacing: 10, fill: true)
    }

    private func request() -> NSView {
        let ask = envH([envSymbol("sparkles", size: TypeScale.body, color: EnvInk.secondary),
                        envLabel("I need a Stripe key to create test refunds. I asked for STRIPE_RESTRICTED_KEY; I will only get a placeholder.",
                                 size: TypeScale.body, color: EnvInk.secondary, wraps: true)], spacing: 8, align: .top)
        let title = envH([envSymbol("lock.shield", size: TypeScale.body, color: EnvSecretsKind.apiSecret.tint),
                          envLabel("Secret request", weight: .semibold),
                          envLabel("from “\(sample.requestChat)”", color: EnvInk.secondary), envSpacer()], spacing: 6)
        let key: (String) -> NSView = { envLabel($0, color: EnvInk.secondary) }
        let value = NSSecureTextField()
        value.focusRingType = .none
        value.placeholderString = "Paste or type the value"
        value.bezelStyle = .roundedBezel
        value.font = .systemFont(ofSize: TypeScale.detail)
        let grid = envGrid([
            [key("Name"), envLabel(sample.requestName, weight: .semibold, mono: true)],
            [key("Goes to"), envH([envHostChip(sample.requestHost),
                                   envLabel("as Authorization: Bearer", size: TypeScale.caption, color: EnvInk.tertiary)], spacing: 6)],
            [key("Why"), envLabel(sample.requestReason)],
            [key("Value"), envSized(value, width: 320)],
            [key("Keep in"), envSized(envRequestScopePicker(model, reload: reload), width: 360)],
        ], columnSpacing: 16, rowSpacing: 8)
        let goesTo = grid.row(at: 1)
        goesTo.rowAlignment = .none
        goesTo.yPlacement = .center
        let keepIn = grid.row(at: 4)
        keepIn.rowAlignment = .none
        keepIn.yPlacement = .top
        let buttons = envH([envSpacer(), EnvButton("Decline", small: true), EnvButton(model.requestSaveTitle, look: .prominent, small: true)])
        let column = envV([
            title, envH([grid, envSpacer()]),
            envLabel("The agent gets only the placeholder $\(sample.requestName). It never sees what you type, and nobody can read the value back after you save.",
                     size: TypeScale.caption, color: EnvInk.secondary, wraps: true),
            buttons,
        ], spacing: 10, fill: true)
        let box = EnvBox(column, padding: envPad(14), fill: EnvInk.surface,
                         border: EnvSecretsKind.apiSecret.tint.withAlphaComponent(0.5), corner: .radius(8))
        return envV([ask, envMaxWidth(box, 640)], spacing: 12, fill: true)
    }
}
#endif
