#if DEBUG
import CmuxNextDesign
import SwiftUI

/// DEBUG ONLY (Environment Secrets Playground), direction 2 "Sentences": one card per value in a
/// narrow column, each card says in plain words where its value can go; choices are large tiles.
struct EnvSentencesDirection: View {
    @Bindable var model: EnvSecretsPlaygroundModel

    private var sample: EnvSecretsSample { model.sample }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                switch model.scene {
                case .empty: empty
                case .paste: paste
                case .saved: cards(sample.saved) { stripe in savedFooter(stripe) }
                case .noHost: noHost
                case .approval: cards(sample.saved) { stripe in approval(stripe) }
                case .audit: audit
                case .revoke: cards(sample.saved) { stripe in revoke(stripe) }
                case .scopes: scopes
                case .request: request
                case .cli: EnvTerminalFrames()
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.vertical, 26).padding(.horizontal, 30)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(sample.environment).font(.system(size: TypeScale.heading, weight: .semibold))
            Text("Values every chat in this environment starts with. Secrets stay out of the machine unless you say otherwise.")
                .font(.system(size: TypeScale.body)).foregroundStyle(EnvInk.secondary)
            HStack(spacing: 6) {
                ForEach(EnvSecretsEntry.Scope.allCases) { scope in
                    Button { model.scope = scope } label: {
                        Label(scope.title, systemImage: scope.symbol).font(.system(size: TypeScale.detail, weight: .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(model.scope == scope ? Color.accentColor.opacity(0.16) : EnvInk.fill))
                            .foregroundStyle(model.scope == scope ? Color.accentColor : EnvInk.secondary)
                    }
                    .buttonStyle(.cmuxPressFillCapsule)
                }
                Spacer()
                Button("Add") {}.buttonStyle(.borderedProminent)
            }
        }
    }

    private func card<Content: View>(highlight: Color? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(EnvInk.surface))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(highlight?.opacity(0.6) ?? EnvInk.line, lineWidth: highlight == nil ? 1 : 1.5))
    }

    private func title(_ entry: EnvSecretsEntry) -> some View {
        HStack(spacing: 8) {
            Text(entry.name).font(.system(size: TypeScale.body, weight: .semibold, design: .monospaced))
            EnvKindBadge(kind: entry.kind)
            Spacer()
            Text(entry.shown).font(EnvInk.mono).foregroundStyle(EnvInk.secondary)
        }
    }

    private func sentence(_ entry: EnvSecretsEntry) -> some View {
        Text(entry.sentence).font(.system(size: TypeScale.body)).foregroundStyle(EnvInk.text).fixedSize(horizontal: false, vertical: true)
    }

    private func cards<Footer: View>(_ rows: [EnvSecretsEntry], @ViewBuilder footer: @escaping (EnvSecretsEntry) -> Footer) -> some View {
        VStack(spacing: 10) {
            ForEach(rows) { entry in
                card(highlight: entry.name == "STRIPE_SECRET_KEY" ? Color.accentColor : nil) {
                    title(entry)
                    sentence(entry)
                    if entry.name == "STRIPE_SECRET_KEY" { footer(entry) } else { EnvProvenance(entry: entry) }
                }
            }
        }
    }

    // MARK: States

    private var empty: some View {
        VStack(spacing: 12) {
            card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Nothing here yet").font(.system(size: TypeScale.title, weight: .semibold))
                    Text("Paste your .env and cmux sorts each line: plain settings, keys for an API, keys for setup only. You check each one before anything is saved.")
                        .font(.system(size: TypeScale.body)).foregroundStyle(EnvInk.secondary).fixedSize(horizontal: false, vertical: true)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(EnvInk.line, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .frame(height: 96)
                        .overlay(VStack(spacing: 4) {
                            Image(systemName: "doc.on.clipboard").font(.system(size: TypeScale.heading)).foregroundStyle(EnvInk.tertiary)
                            Text("Paste or drop a .env file here").font(.system(size: TypeScale.detail)).foregroundStyle(EnvInk.secondary)
                        })
                    HStack {
                        Button("Paste .env") {}.buttonStyle(.borderedProminent)
                        Button("Add one value") {}
                    }
                }
            }
            HStack(alignment: .top, spacing: 10) {
                ForEach([EnvSecretsKind.variable, .apiSecret, .setupSecret]) { kind in
                    VStack(alignment: .leading, spacing: 4) {
                        EnvKindBadge(kind: kind, long: true)
                        Text(kind.promise).font(.system(size: TypeScale.caption)).foregroundStyle(EnvInk.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var paste: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("7 lines to check").font(.system(size: TypeScale.title, weight: .semibold))
            Text("cmux picked a type for each line from its name and value. Change any of them before you save.")
                .font(.system(size: TypeScale.detail)).foregroundStyle(EnvInk.secondary)
            ForEach(model.review) { entry in
                card(highlight: entry.kind == .envSecret ? EnvInk.warning : nil) {
                    HStack(spacing: 8) {
                        Text(entry.name).font(.system(size: TypeScale.body, weight: .semibold, design: .monospaced))
                        Spacer()
                        EnvKindMenu(model: model, entry: entry)
                    }
                    sentence(entry)
                    if let reason = entry.reason {
                        Text("Picked because: " + String(reason.prefix(1)).lowercased() + String(reason.dropFirst()) + ".")
                            .font(.system(size: TypeScale.caption)).foregroundStyle(EnvInk.tertiary)
                    }
                    if entry.kind == .envSecret {
                        EnvNote(tone: .warning, text: "The agent and any code it runs can read and print this. A team environment needs an admin to allow it.")
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") {}
                Button("Save 7 values") {}.buttonStyle(.borderedProminent)
            }
        }
    }

    private func savedFooter(_ entry: EnvSecretsEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 4) {
                ForEach(entry.hosts, id: \.self) { EnvHostChip(host: $0) }  // visible-only: fixed sample list of at most 4 items
                Spacer()
                EnvProvenance(entry: entry)
            }
            Text("The value is write-only: cmux shows its last 4 characters and never the rest. There is no Reveal, Copy or Export.")
                .font(.system(size: TypeScale.caption)).foregroundStyle(EnvInk.tertiary)
            HStack {
                Button("Enter new value") {}
                Button("Edit hosts") {}
                Spacer()
                Button("Revoke now", role: .destructive) {}.foregroundStyle(EnvInk.danger)
            }
            .controlSize(.small)
        }
    }

    private var noHost: some View {
        let entry = sample.noHost
        return card(highlight: EnvInk.danger) {
            title(entry)
            Text("No host yet, so no request can carry this secret. Choose how it is used:")
                .font(.system(size: TypeScale.body))
            HStack(alignment: .top, spacing: 10) {
                choice(kind: .apiSecret, title: "Add a host", body: "Name the API that needs it, for example api.example.com. It stays out of the machine.",
                       button: "Add host", primary: false)
                choice(kind: .setupSecret, title: "Use for setup only", body: "The setup script reads it, then cmux removes it before the agent starts.",
                       button: "Use for setup", primary: true)
                choice(kind: .envSecret, title: "Put in the environment", body: "The agent and any code it runs can read and print it. Use it only for tools that must.",
                       button: "Put in environment…", primary: false)
            }
        }
    }

    private func choice(kind: EnvSecretsKind, title: String, body: String, button: String, primary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: kind.symbol).font(.system(size: TypeScale.title)).foregroundStyle(kind.tint)
            Text(title).font(.system(size: TypeScale.detail, weight: .semibold))
            Text(body).font(.system(size: TypeScale.caption)).foregroundStyle(EnvInk.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if primary {
                Button(button) {}.buttonStyle(.borderedProminent).controlSize(.small)
            } else {
                Button(button) {}.controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(EnvInk.fill.opacity(0.7)))
    }

    private func approval(_ entry: EnvSecretsEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack(spacing: 4) {
                ForEach(entry.hosts, id: \.self) { EnvHostChip(host: $0) }  // visible-only: fixed sample list of at most 4 items
                EnvHostChip(host: sample.pendingHost, added: true)
            }
            HStack(alignment: .top, spacing: 0) {
                step("Asked", "\(sample.pendingBy) · \(sample.pendingAt)", done: true)
                step("Admin approves", "Touch ID on a Mac", done: false, current: true)
                step("Applied", "Then chats may send to it", done: false)
            }
            Text("Nothing changes until an admin approves. Until then, the secret goes only to api.stripe.com.")
                .font(.system(size: TypeScale.detail)).foregroundStyle(EnvInk.secondary)
            HStack {
                Button { } label: { Label("Approve with Touch ID", systemImage: "touchid") }.buttonStyle(.borderedProminent)
                Button("Decline") {}
            }
            .controlSize(.small)
        }
    }

    private func step(_ title: String, _ caption: String, done: Bool, current: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: done ? "checkmark.circle.fill" : current ? "circle.dotted.circle" : "circle")
                .foregroundStyle(done ? EnvInk.good : current ? EnvInk.warning : EnvInk.tertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: TypeScale.detail, weight: .semibold))
                Text(caption).font(.system(size: TypeScale.caption)).foregroundStyle(EnvInk.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var audit: some View {
        let entry = sample.saved[0]
        return card {
            title(entry)
            sentence(entry)
            Divider()
            Text("History").font(.system(size: TypeScale.body, weight: .semibold))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(sample.audit) { event in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(spacing: 0) {
                            Image(systemName: event.outcome.symbol).font(.system(size: TypeScale.caption, weight: .semibold))
                                .foregroundStyle(event.outcome.tint).frame(width: 22, height: 22)
                                .background(Circle().fill(event.outcome.tint.opacity(0.12)))
                            if event.id != sample.audit.last?.id { Rectangle().fill(EnvInk.line).frame(width: 1, height: 18) }
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(line(event)).font(.system(size: TypeScale.detail))
                            Text(event.time).font(.system(size: TypeScale.caption)).foregroundStyle(EnvInk.secondary).monospacedDigit()
                        }
                        Spacer()
                    }
                }
            }
            Text("The value itself is never logged.").font(.system(size: TypeScale.caption)).foregroundStyle(EnvInk.tertiary)
        }
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

    private func revoke(_ entry: EnvSecretsEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("Revoke now?").font(.system(size: TypeScale.title, weight: .semibold))
            Text("\(entry.name) stops working everywhere at once. These \(sample.runningChats.count) running chats lose it now:")
                .font(.system(size: TypeScale.body))
            VStack(alignment: .leading, spacing: 4) {
                ForEach(sample.runningChats, id: \.self) { chat in  // visible-only: fixed sample list of at most 4 items
                    Label(chat, systemImage: "bubble.left").font(.system(size: TypeScale.detail)).foregroundStyle(EnvInk.secondary)
                }
            }
            Text("Requests to api.stripe.com fail until you enter a new value. The history keeps the revoke.")
                .font(.system(size: TypeScale.detail)).foregroundStyle(EnvInk.secondary)
            HStack {
                Spacer()
                Button("Keep it") {}
                Button(role: .destructive) {} label: { Label("Revoke with Touch ID", systemImage: "touchid") }.buttonStyle(.borderedProminent).tint(EnvInk.danger)
            }
        }
    }

    private var scopes: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(EnvSecretsEntry.Scope.allCases.reversed())) { scope in
                    VStack(alignment: .leading, spacing: 4) {
                        EnvScopeTag(scope: scope, strong: true)
                        Text(scope.caption).font(.system(size: TypeScale.caption)).foregroundStyle(EnvInk.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10).frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(EnvInk.fill.opacity(0.7)))
                    if scope != .team {
                        Image(systemName: "chevron.right").foregroundStyle(EnvInk.tertiary).padding(.top, 28)
                    }
                }
            }
            Text("The first scope that sets a name wins.").font(.system(size: TypeScale.detail)).foregroundStyle(EnvInk.secondary)
            ForEach(sample.layers) { layer in
                card {
                    HStack(spacing: 8) {
                        Text(layer.name).font(.system(size: TypeScale.body, weight: .semibold, design: .monospaced))
                        EnvKindBadge(kind: layer.kind)
                        Spacer()
                        Text(layer.value(layer.winner) ?? "").font(EnvInk.mono)
                    }
                    Text(provenance(layer)).font(.system(size: TypeScale.detail)).foregroundStyle(EnvInk.secondary)
                }
            }
        }
    }

    private func provenance(_ layer: EnvSecretsSample.Layer) -> String {
        let others = EnvSecretsEntry.Scope.allCases.filter { $0 != layer.winner && layer.value($0) != nil }
        let from = "From \(layer.winner.title)."
        guard !others.isEmpty else { return from }
        return from + " Overrides " + ListFormatter.localizedString(byJoining: others.map { "\($0.title) (\(layer.value($0) ?? ""))" }) + "."
    }

    private var request: some View {
        card(highlight: EnvSecretsKind.apiSecret.tint) {
            Text("“\(sample.requestChat)” asks for a secret").font(.system(size: TypeScale.title, weight: .semibold))
            Text("It wants \(sample.requestName), to send to \(sample.requestHost).").font(.system(size: TypeScale.body))
            Text("“\(sample.requestReason)”").font(.system(size: TypeScale.body)).foregroundStyle(EnvInk.secondary)
            SecureField("Type or paste the value", text: .constant("")).textFieldStyle(.roundedBorder)
                .font(.system(size: TypeScale.field))
            VStack(alignment: .leading, spacing: 6) {
                promise("keyboard", "You type it here. The agent never sees it.")
                promise("curlybraces", "The agent gets $\(sample.requestName), a placeholder.")
                promise("arrow.up.right", "cmux adds the value only on requests to \(sample.requestHost).")
                promise("eye.slash", "After you save, nobody can read it back: not you, not an agent.")
            }
            Divider()
            Text("Where to keep it").font(.system(size: TypeScale.detail, weight: .semibold))
            EnvRequestScopePicker(model: model)
            HStack {
                Spacer()
                Button("Decline") {}
                Button(model.requestSaveTitle) {}.buttonStyle(.borderedProminent)
            }
        }
    }

    private func promise(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).font(.system(size: TypeScale.detail)).foregroundStyle(EnvInk.text)
    }
}
#endif
