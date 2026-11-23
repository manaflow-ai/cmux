#if DEBUG
import AppKit
import CmuxNextDesign

// DEBUG ONLY (Environment Secrets Playground): the small parts the three directions share, as AppKit
// views made by pure functions (each part is stateless: it is rebuilt when the model changes). Kept in
// one prototype file on purpose: the playground is deleted after the pick.

/// The semantic colours every direction draws in; they follow light and dark.
struct EnvInk {
    static let text = NSColor.labelColor
    static let secondary = NSColor.secondaryLabelColor
    static let tertiary = NSColor.tertiaryLabelColor
    static let line = NSColor.separatorColor
    static let surface = NSColor.controlBackgroundColor  // glass-opaque-allow: a DEBUG mock of a settings page's cards, not an overlay
    static let canvas = NSColor.windowBackgroundColor  // glass-opaque-allow: the DEBUG playground window's own page background, not an overlay
    static let fill = envAlpha(NSColor.quaternaryLabelColor, 0.5)
    static let warning = NSColor.systemOrange
    static let danger = NSColor.systemRed
    static let good = NSColor.systemGreen
}

/// `color` with its own alpha multiplied by `factor`, resolved per look (as SwiftUI's `.opacity` does;
/// `withAlphaComponent` replaces the alpha instead, which makes a translucent system colour too strong).
func envAlpha(_ color: NSColor, _ factor: CGFloat) -> NSColor {
    NSColor(name: nil) { appearance in
        var resolved = color
        appearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) ?? color }
        return resolved.withAlphaComponent(resolved.alphaComponent * factor)
    }
}

/// A row type's tag: its symbol and short name (or full title when `long`) in its tint, on a capsule.
func envKindBadge(_ kind: EnvSecretsKind, long: Bool = false) -> NSView {
    let ink = kind == .variable ? EnvInk.secondary : kind.tint
    let label = envIconLabel(long ? kind.title : kind.short, symbol: kind.symbol, size: TypeScale.caption, weight: .semibold, color: ink)
    return EnvBox(label, padding: NSEdgeInsets(top: 2, left: 7, bottom: 2, right: 7),
                  fill: envAlpha(kind.tint, kind == .variable ? 0.10 : 0.14), corner: .capsule)
}

/// A host the secret may go to, in monospace; `added` marks one waiting for approval, `removed` one struck out.
func envHostChip(_ host: String, added: Bool = false, removed: Bool = false) -> NSView {
    let ink = added ? EnvInk.warning : removed ? EnvInk.tertiary : EnvInk.text
    var parts: [NSView] = []
    if added { parts.append(envSymbol("plus", size: TypeScale.caption, weight: .semibold, color: ink)) }  // plus-button-allow: a prototype glyph inside a DEBUG playground
    parts.append(envLabel(host, size: TypeScale.caption, color: ink, mono: true, strike: removed))
    return EnvBox(envH(parts, spacing: 4), padding: NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6),
                  fill: added ? envAlpha(EnvInk.warning, 0.12) : EnvInk.fill,
                  border: added ? envAlpha(EnvInk.warning, 0.5) : nil, corner: .radius(4), dash: added ? [3, 2] : nil)
}

/// How strong a one-line callout is.
enum EnvNoteTone { case info, warning, danger }

/// A callout the full width it is given: an icon and a wrapping sentence, in the tone's colour.
func envNote(_ tone: EnvNoteTone, _ text: String) -> NSView {
    let (symbol, color): (String, NSColor) = switch tone {
    case .info: ("info.circle", EnvInk.secondary)
    case .warning: ("exclamationmark.triangle.fill", EnvInk.warning)
    case .danger: ("xmark.octagon.fill", EnvInk.danger)
    }
    let row = envH([envSymbol(symbol, color: color),
                    envLabel(text, color: tone == .info ? EnvInk.secondary : EnvInk.text, wraps: true)],
                   spacing: 6, align: .firstBaseline)
    return EnvBox(row, padding: envPad(h: 10, v: 7), fill: envAlpha(color, tone == .info ? 0.06 : 0.10), corner: .radius(6))
}

/// A scope tag (Team, Personal, Chat); `strong` draws it in the text colour and semibold.
func envScopeTag(_ scope: EnvSecretsEntry.Scope, strong: Bool = false) -> NSView {
    envIconLabel(scope.title, symbol: scope.symbol, size: TypeScale.caption, weight: strong ? .semibold : .regular,
                 color: strong ? EnvInk.text : EnvInk.secondary)
}

/// "Set by NAME · DATE", the write-only line under a saved secret.
func envProvenance(_ entry: EnvSecretsEntry) -> NSView {
    envLabel("Set by \(entry.setBy) · \(entry.setAt)\(entry.version > 1 ? " · version \(entry.version)" : "")",
             size: TypeScale.caption, color: EnvInk.secondary, digits: true)
}

/// The type menu of a review row, drawn as a borderless menu: the type's symbol and short name in the text
/// colour, then a small chevron; a click lists the four types.
func envKindMenu(_ model: EnvSecretsPlaygroundModel, _ entry: EnvSecretsEntry, reload: @escaping @MainActor () -> Void) -> NSView {
    let kind = model.kind(of: entry)
    let content = envH([envIconLabel(kind.short, symbol: kind.symbol, size: TypeScale.body, color: EnvInk.text),
                        envSymbol("chevron.down", size: TypeScale.caption, weight: .semibold, color: EnvInk.text)], spacing: 3)
    return EnvClickArea(content) { area in
        let menu = NSMenu()
        for kind in EnvSecretsKind.allCases {  // visible-only: the four row types
            menu.addItem(EnvMenuAction.item(kind.title, symbol: kind.symbol) { model.setKind(kind, for: entry); reload() })
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: area.bounds.height + 2), in: area)
    }
}

/// The history table of a secret: time, result, chat or person, host, detail.
func envAuditTable(_ events: [EnvSecretsAuditEvent]) -> NSView {
    let titles = ["Time", "Result", "Chat or person", "Host", ""].map {
        envLabel($0, size: TypeScale.caption, weight: .semibold, color: EnvInk.tertiary) as NSView?
    }
    let rows: [[NSView?]] = events.map { event in  // visible-only: a fixed sample history of 7 lines
        [envLabel(event.time, color: EnvInk.secondary, digits: true),
         envIconLabel(event.outcome.title, symbol: event.outcome.symbol, color: event.outcome.tint),
         envLabel(event.who),
         envLabel(event.host, size: TypeScale.caption, color: EnvInk.secondary, mono: true),
         envLabel(event.detail, color: EnvInk.secondary)]
    }
    let grid = envGrid([titles])
    envGridDivider(grid)
    for row in rows { grid.addRow(with: row.map { $0 ?? NSGridCell.emptyContentView }) }
    return grid
}

/// The agent request card's "where to keep it" choice (``EnvRequestScopeChoice``), the same in every direction:
/// one radio row per scope, the picked one filled with the accent colour.
func envRequestScopePicker(_ model: EnvSecretsPlaygroundModel, reload: @escaping @MainActor () -> Void) -> NSView {
    let rows: [NSView] = model.requestScopeChoices.map { choice in  // visible-only: the three scopes
        let picked = choice.scope == model.requestScope
        var tag: [NSView] = [envScopeTag(choice.scope, strong: picked)]
        if choice.needsAdminTouchID { tag.append(envSymbol("touchid", size: TypeScale.caption, color: EnvInk.warning)) }
        let tagRow = envH(tag, spacing: 6)
        // A stack has no intrinsic width, so hugging does not hold it: pull it to its content's width.
        let narrow = tagRow.widthAnchor.constraint(equalToConstant: 0)
        narrow.priority = .init(2)
        narrow.isActive = true
        let text = envV([tagRow, envLabel(choice.note, size: TypeScale.caption, color: EnvInk.secondary)], spacing: 1)
        let radio = envSymbol(picked ? "largecircle.fill.circle" : "circle", color: picked ? .controlAccentColor : EnvInk.tertiary)
        let row = envH([radio, text, envSpacer()], spacing: 8, align: .top)
        return EnvClickArea(row) { model.requestScope = choice.scope; reload() }
    }
    return envV(rows, spacing: 6, fill: true)
}
#endif
