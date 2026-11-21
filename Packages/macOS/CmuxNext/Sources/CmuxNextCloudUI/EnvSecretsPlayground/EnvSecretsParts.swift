#if DEBUG
import CmuxNextDesign
import SwiftUI

// DEBUG ONLY (Environment Secrets Playground): the small parts the three directions share. They are
// tiny one-purpose views, kept in one prototype file on purpose (the playground is deleted after the
// pick, as the prototype workflow asks).

/// The semantic colors every direction draws in; they follow light and dark.
struct EnvInk {
    static let text = Color(nsColor: .labelColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let tertiary = Color(nsColor: .tertiaryLabelColor)
    static let line = Color(nsColor: .separatorColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let fill = Color(nsColor: .quaternaryLabelColor).opacity(0.5)
    static let warning = Color(nsColor: .systemOrange)
    static let danger = Color(nsColor: .systemRed)
    static let good = Color(nsColor: .systemGreen)
    static let mono = Font.system(size: TypeScale.detail, design: .monospaced)
    static let monoStrong = Font.system(size: TypeScale.detail, weight: .semibold, design: .monospaced)
}

/// A row type's tag: its symbol and short name in its tint.
struct EnvKindBadge: View {
    let kind: EnvSecretsKind
    var long = false

    var body: some View {
        Label(long ? kind.title : kind.short, systemImage: kind.symbol)
            .labelStyle(.titleAndIcon)
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(kind == .variable ? EnvInk.secondary : kind.tint)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(kind.tint.opacity(kind == .variable ? 0.10 : 0.14)))
            .fixedSize()
    }
}

/// A host the secret may go to, in monospace; `added` marks one waiting for approval, `removed` one struck out.
struct EnvHostChip: View {
    let host: String
    var added = false
    var removed = false

    var body: some View {
        HStack(spacing: 4) {
            if added { Image(systemName: "plus").font(.system(size: TypeScale.caption, weight: .semibold)) }  // plus-button-allow: a prototype glyph inside a DEBUG playground
            Text(host).font(.system(size: TypeScale.caption, design: .monospaced)).strikethrough(removed)
        }
        .foregroundStyle(added ? EnvInk.warning : removed ? EnvInk.tertiary : EnvInk.text)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(added ? EnvInk.warning.opacity(0.12) : EnvInk.fill))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(added ? EnvInk.warning.opacity(0.5) : .clear, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        .fixedSize()
    }
}

/// A one-line callout: an icon, a sentence, in the tone's color.
struct EnvNote: View {
    enum Tone { case info, warning, danger }
    let tone: Tone
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).foregroundStyle(tone == .info ? EnvInk.secondary : EnvInk.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: TypeScale.detail))
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.opacity(tone == .info ? 0.06 : 0.10)))
    }

    private var symbol: String {
        switch tone {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle.fill"
        case .danger: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch tone {
        case .info: EnvInk.secondary
        case .warning: EnvInk.warning
        case .danger: EnvInk.danger
        }
    }
}

/// A scope tag (Team, Personal, Chat).
struct EnvScopeTag: View {
    let scope: EnvSecretsEntry.Scope
    var strong = false

    var body: some View {
        Label(scope.title, systemImage: scope.symbol)
            .font(.system(size: TypeScale.caption, weight: strong ? .semibold : .regular))
            .foregroundStyle(strong ? EnvInk.text : EnvInk.secondary)
            .fixedSize()
    }
}

/// "Set by NAME · DATE", the write-only line under a saved secret.
struct EnvProvenance: View {
    let entry: EnvSecretsEntry

    var body: some View {
        Text("Set by \(entry.setBy) · \(entry.setAt)\(entry.version > 1 ? " · version \(entry.version)" : "")")
            .font(.system(size: TypeScale.caption)).foregroundStyle(EnvInk.secondary)
            .monospacedDigit()
    }
}

/// The type menu of a review row: picks any of the four types.
struct EnvKindMenu: View {
    let model: EnvSecretsPlaygroundModel
    let entry: EnvSecretsEntry

    var body: some View {
        Menu {
            ForEach(EnvSecretsKind.allCases) { kind in
                Button { model.setKind(kind, for: entry) } label: { Label(kind.title, systemImage: kind.symbol) }
            }
        } label: {
            EnvKindBadge(kind: model.kind(of: entry))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
    }
}

/// The history table of a secret: time, who, host, result.
struct EnvAuditTable: View {
    let events: [EnvSecretsAuditEvent]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
            GridRow {
                ForEach(["Time", "Result", "Chat or person", "Host", ""], id: \.self) { title in  // visible-only: fixed sample list of at most 4 items
                    Text(title).font(.system(size: TypeScale.caption, weight: .semibold)).foregroundStyle(EnvInk.tertiary)
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(events) { event in
                GridRow {
                    Text(event.time).monospacedDigit().foregroundStyle(EnvInk.secondary)
                    Label(event.outcome.title, systemImage: event.outcome.symbol).foregroundStyle(event.outcome.tint)
                    Text(event.who).lineLimit(1)
                    Text(event.host).font(.system(size: TypeScale.caption, design: .monospaced)).foregroundStyle(EnvInk.secondary)
                    Text(event.detail).foregroundStyle(EnvInk.secondary)
                }
                .font(.system(size: TypeScale.detail))
            }
        }
    }
}
#endif
