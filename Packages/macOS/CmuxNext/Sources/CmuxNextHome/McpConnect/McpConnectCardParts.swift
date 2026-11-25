import CmuxNextDesign
import SwiftUI

/// The pieces every card style is made of: the facts, the risk lines, the scope menu, the buttons,
/// the private key field and the phase line. Each style arranges them; none adds a fact of its own.
struct McpConnectFacts: View {
    let card: McpConnectCard
    let colors: McpConnectCardColors

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
            switch card.transport {
            case .remote(let url):
                row(McpConnectStrings.server, url, mono: true)
            case .local(let argv, let sha, _):
                row(McpConnectStrings.command, argv.joined(separator: " "), mono: true)
                row(McpConnectStrings.binary, "sha256:" + sha.prefix(16) + "…", mono: true)
            }
            row(McpConnectStrings.by, card.publisher, mono: false)
            row(McpConnectStrings.access, McpConnectAccessText(card: card).text, mono: false)
        }
    }

    private func row(_ label: String, _ value: String, mono: Bool) -> some View {
        GridRow {
            Text(label).font(colors.caption).foregroundStyle(colors.tertiary)
            Text(value).font(mono ? colors.mono : colors.body).foregroundStyle(colors.text)
                .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
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

/// The lines that say why to look twice.
struct McpConnectRiskLines: View {
    let card: McpConnectCard
    let colors: McpConnectCardColors

    var lines: [String] {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(lines, id: \.self) { line in
                Label(line, systemImage: "exclamationmark.triangle").font(colors.caption).foregroundStyle(colors.attention)
            }
        }
    }
}

/// The badge: Verified (registry, exact URL) or Unverified.
struct McpConnectBadge: View {
    let card: McpConnectCard
    let colors: McpConnectCardColors

    var body: some View {
        let ok = card.verified && !card.idn
        Label(ok ? McpConnectStrings.verified : McpConnectStrings.unverified,
              systemImage: ok ? "checkmark.seal" : "questionmark.diamond")
            .font(colors.caption)
            .foregroundStyle(ok ? colors.secondary : colors.attention)
    }
}

/// Who gets the server.
struct McpConnectScopeMenu: View {
    let flow: McpConnectCardFlow
    let colors: McpConnectCardColors
    let actions: McpConnectCardActions

    var body: some View {
        Menu {
            ForEach(McpConnectCard.Scope.allCases, id: \.self) { scope in
                Button(McpConnectStrings.scope(scope)) { actions.choose(scope) }
            }
        } label: {
            Text(McpConnectStrings.scope(flow.scope)).font(colors.body).foregroundStyle(colors.text)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// Cancel and Connect (Return), or the private key field, or the phase line, by phase.
struct McpConnectControls: View {
    let flow: McpConnectCardFlow
    let colors: McpConnectCardColors
    let actions: McpConnectCardActions
    @State private var key = ""

    var body: some View {
        switch flow.phase {
        case .ask:
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                CmuxDialogActionButton(McpConnectStrings.cancel, hint: .escape, action: actions.cancel)
                CmuxDialogActionButton(McpConnectStrings.connect, hint: .return, action: actions.connect)
            }
            .controlSize(.regular)
        case .enterKey:
            VStack(alignment: .leading, spacing: 6) {
                SecureField(keyName, text: $key).textFieldStyle(.roundedBorder).font(colors.mono)
                    .focusEffectDisabled()
                    .onSubmit(send)
                Text(McpConnectStrings.keyPrivate).font(colors.caption).foregroundStyle(colors.tertiary)
                HStack(spacing: 8) {
                    if case .key(_, optional: true) = flow.card.auth {
                        Button(McpConnectStrings.skipKey) { actions.submitKey(McpConnectKey("")) }
                    }
                    Spacer(minLength: 0)
                    CmuxDialogActionButton(McpConnectStrings.cancel, hint: .escape, action: actions.cancel)
                    CmuxDialogActionButton(McpConnectStrings.save, hint: .return, action: send).disabled(key.isEmpty)
                }
            }
        case .signingIn:
            McpConnectPhaseLine(text: McpConnectStrings.signingIn, busy: true, colors: colors, cancel: actions.cancel)
        case .connecting:
            McpConnectPhaseLine(text: McpConnectStrings.connecting, busy: true, colors: colors, cancel: actions.cancel)
        case .connected(let tools):
            McpConnectToolList(card: flow.card, tools: tools, colors: colors)
        case .declined:
            Text(McpConnectStrings.declined).font(colors.caption).foregroundStyle(colors.tertiary)
        case .failed(let reason):
            Text(McpConnectStrings.failed(reason)).font(colors.caption).foregroundStyle(colors.danger)
        }
    }

    private var keyName: String {
        if case .key(let name, _) = flow.card.auth { return name }
        return ""
    }

    private func send() {
        guard !key.isEmpty else { return }
        let typed = McpConnectKey(key)
        key = ""
        actions.submitKey(typed)
    }
}

/// A waiting line with Cancel.
struct McpConnectPhaseLine: View {
    let text: String
    let busy: Bool
    let colors: McpConnectCardColors
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if busy { ThemedSpinner(size: 12).frame(width: 12, height: 12) }
            Text(text).font(colors.body).foregroundStyle(colors.secondary)
            Spacer(minLength: 0)
            Button(McpConnectStrings.cancel, action: cancel)
        }
    }
}

/// The connected result: the count line and each tool with its class; a held tool says why.
struct McpConnectToolList: View {
    let card: McpConnectCard
    let tools: [McpConnectCard.Tool]
    let colors: McpConnectCardColors
    @State private var open = false

    var body: some View {
        let writes = tools.filter { $0.kind != .read }.count
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(tools, id: \.name) { tool in
                    HStack(spacing: 6) {
                        Image(systemName: symbol(tool)).foregroundStyle(tool.flagged ? colors.danger : colors.tertiary)
                        Text(tool.name).font(colors.mono).foregroundStyle(colors.text)
                        if tool.flagged {
                            Text(McpConnectStrings.flagged).font(colors.caption).foregroundStyle(colors.danger)
                        }
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            Label(McpConnectStrings.connected(card.title, tools: tools.count, writes: writes), systemImage: "checkmark.circle")
                .font(colors.body).foregroundStyle(colors.text)
        }
    }

    private func symbol(_ tool: McpConnectCard.Tool) -> String {
        if tool.flagged { return "hand.raised" }
        switch tool.kind {
        case .read: return "eye"
        case .write: return "pencil"
        case .destructive: return "trash"
        }
    }
}

/// The server's mark: the first letter on a gray tile (no brand art is bundled).
struct McpConnectMark: View {
    let title: String
    let size: CGFloat
    let colors: McpConnectCardColors

    var body: some View {
        Text(String(title.prefix(1)).uppercased())
            .font(Font(Typography.system(.default, size: size * 0.5, weight: .semibold)))
            .foregroundStyle(colors.text)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(colors.fill))
    }
}
