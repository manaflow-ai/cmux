#if DEBUG
import CmuxNextDesign
import SwiftUI

/// DEBUG ONLY (Environment Secrets Playground), direction 1 "Ledger": a dense table, one line per
/// value, and a row's details, approval, history or revoke open in place under it.
struct EnvLedgerDirection: View {
    @Bindable var model: EnvSecretsPlaygroundModel

    private var sample: EnvSecretsSample { model.sample }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            switch model.scene {
            case .empty: empty
            case .paste: paste
            case .saved: table(sample.saved, open: "STRIPE_SECRET_KEY") { details($0) }
            case .noHost: noHost
            case .approval: table(sample.saved, open: "STRIPE_SECRET_KEY") { approval($0) }
            case .audit: table(sample.saved, open: "STRIPE_SECRET_KEY") { _ in history }
            case .revoke: table(sample.saved, open: "STRIPE_SECRET_KEY") { revoke($0) }
            case .scopes: scopes
            case .request: request
            case .cli: EnvTerminalFrames()
            }
            Spacer(minLength: 0)
        }
        .padding(22)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Environment variables").font(.system(size: TypeScale.title, weight: .semibold))
                Text("\(sample.environment) · \(sample.team) team").font(.system(size: TypeScale.detail)).foregroundStyle(EnvInk.secondary)
            }
            Spacer()
            Picker("Scope", selection: $model.scope) {
                ForEach(EnvSecretsEntry.Scope.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 230)
            Button("Paste .env") {}
            Button("Add variable") {}.buttonStyle(.borderedProminent)
        }
    }

    private var columns: some View {
        HStack(spacing: 0) {
            Text("Name").frame(width: 210, alignment: .leading)
            Text("Type").frame(width: 130, alignment: .leading)
            Text("Value").frame(width: 120, alignment: .leading)
            Text("Goes to").frame(maxWidth: .infinity, alignment: .leading)
            Text("Changed").frame(width: 150, alignment: .leading)
        }
        .font(.system(size: TypeScale.caption, weight: .semibold)).foregroundStyle(EnvInk.tertiary)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func line(_ entry: EnvSecretsEntry, open: Bool) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: TypeScale.caption, weight: .semibold))
                    .foregroundStyle(EnvInk.tertiary).frame(width: 10)
                Text(entry.name).font(EnvInk.monoStrong).lineLimit(1)
            }
            .frame(width: 210, alignment: .leading)
            EnvKindBadge(kind: entry.kind).frame(width: 130, alignment: .leading)
            Text(entry.shown).font(EnvInk.mono).foregroundStyle(entry.kind == .variable ? EnvInk.text : EnvInk.secondary)
                .frame(width: 120, alignment: .leading)
            goesTo(entry).frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.setAt).font(.system(size: TypeScale.caption)).foregroundStyle(EnvInk.secondary).monospacedDigit()
                .frame(width: 150, alignment: .leading)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(open ? EnvInk.fill.opacity(0.6) : .clear)
    }

    @ViewBuilder private func goesTo(_ entry: EnvSecretsEntry) -> some View {
        switch entry.kind {
        case .apiSecret:
            HStack(spacing: 4) {
                ForEach(entry.hosts, id: \.self) { EnvHostChip(host: $0) }  // visible-only: fixed sample list of at most 4 items
            }
        case .setupSecret: Text("Setup script only").font(.system(size: TypeScale.detail)).foregroundStyle(EnvInk.secondary)
        case .envSecret: Text("Every process in the machine").font(.system(size: TypeScale.detail)).foregroundStyle(EnvInk.warning)
        case .variable: Text("Every process in the machine").font(.system(size: TypeScale.detail)).foregroundStyle(EnvInk.secondary)
        }
    }

    private func table<Detail: View>(_ rows: [EnvSecretsEntry], open: String, @ViewBuilder detail: (EnvSecretsEntry) -> Detail) -> some View {
        VStack(spacing: 0) {
            columns
            Divider()
            ForEach(rows) { entry in
                line(entry, open: entry.name == open)
                if entry.name == open {
                    detail(entry).padding(.leading, 28).padding(.trailing, 12).padding(.vertical, 12)
                        .background(EnvInk.fill.opacity(0.6))
                }
                Divider()
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(EnvInk.surface))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(EnvInk.line))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: States

    private var empty: some View {
        VStack(spacing: 0) {
            columns
            Divider()
            VStack(spacing: 10) {
                Image(systemName: "key.horizontal").font(.system(size: TypeScale.heading)).foregroundStyle(EnvInk.tertiary)
                Text("No variables in \(sample.environment) yet").font(.system(size: TypeScale.field, weight: .semibold))
                Text("Paste a .env file or add one variable. Secret values are write-only after you save.")
                    .font(.system(size: TypeScale.detail)).foregroundStyle(EnvInk.secondary)
                HStack {
                    Button("Paste .env") {}.buttonStyle(.borderedProminent)
                    Button("Add variable") {}
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 56)
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(EnvInk.surface))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(EnvInk.line))
    }

    private var paste: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Pasted 7 lines. Check each type, then save.", systemImage: "doc.on.clipboard").font(.system(size: TypeScale.detail, weight: .semibold))
                Spacer()
                Text("4 secrets · 2 variables · 1 needs care").font(.system(size: TypeScale.caption)).foregroundStyle(EnvInk.secondary)
            }
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("Name").frame(width: 190, alignment: .leading)
                    Text("Type").frame(width: 170, alignment: .leading)
                    Text("Goes to").frame(width: 230, alignment: .leading)
                    Text("Why this type").frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: TypeScale.caption, weight: .semibold)).foregroundStyle(EnvInk.tertiary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                Divider()
                ForEach(model.review) { entry in
                    HStack(spacing: 0) {
                        Text(entry.name).font(EnvInk.monoStrong).frame(width: 190, alignment: .leading)
                        EnvKindMenu(model: model, entry: entry).frame(width: 170, alignment: .leading)
                        reviewTarget(entry).frame(width: 230, alignment: .leading)
                        Text(entry.reason ?? "").font(.system(size: TypeScale.caption)).foregroundStyle(EnvInk.secondary).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    if entry.kind == .envSecret {
                        EnvNote(tone: .warning, text: "The agent and any code it runs can read and print LEGACY_LICENSE. cmux masks it in the terminal and the transcript. Team environments need an admin to allow this type.")
                            .padding(.horizontal, 12).padding(.bottom, 8)
                    }
                    Divider()
                }
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(EnvInk.surface))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(EnvInk.line))
            HStack {
                Text("Secret values are write-only after you save. Only the last 4 characters stay visible.")
                    .font(.system(size: TypeScale.caption)).foregroundStyle(EnvInk.secondary)
                Spacer()
                Button("Cancel") {}
                Button("Save 7 values") {}.buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder private func reviewTarget(_ entry: EnvSecretsEntry) -> some View {
        switch entry.kind {
        case .apiSecret:
            HStack(spacing: 4) {
                ForEach(entry.hosts, id: \.self) { EnvHostChip(host: $0) }  // visible-only: fixed sample list of at most 4 items
                Text(entry.delivery?.title ?? "").font(.system(size: TypeScale.caption)).foregroundStyle(EnvInk.tertiary).lineLimit(1)
            }
        case .setupSecret: Text("Setup script, then removed").font(.system(size: TypeScale.detail)).foregroundStyle(EnvInk.secondary)
        case .envSecret: Text("Machine environment").font(.system(size: TypeScale.detail)).foregroundStyle(EnvInk.warning)
        case .variable: Text(entry.value).font(EnvInk.mono)
        }
    }

    private func details(_ entry: EnvSecretsEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    Text("Value").foregroundStyle(EnvInk.secondary)
                    HStack(spacing: 8) {
                        Text("•••• \(entry.last4)").font(EnvInk.mono)
                        Text("Write-only. There is no Reveal, Copy or Export, for you or for an agent.").font(.system(size: TypeScale.caption)).foregroundStyle(EnvInk.tertiary)
                    }
                }
                GridRow {
                    Text("Hosts").foregroundStyle(EnvInk.secondary)
                    HStack(spacing: 4) { ForEach(entry.hosts, id: \.self) { EnvHostChip(host: $0) } }  // visible-only: fixed sample list of at most 4 items
                }
                GridRow {
                    Text("Sent as").foregroundStyle(EnvInk.secondary)
                    Text(entry.delivery?.title ?? "").font(EnvInk.mono)
                }
                GridRow {
                    Text("Set by").foregroundStyle(EnvInk.secondary)
                    EnvProvenance(entry: entry)
                }
            }
            .font(.system(size: TypeScale.detail))
            HStack {
                Button("Enter new value…") {}
                Button("Edit hosts…") {}
                Button("History") {}
                Spacer()
                Button("Revoke now", role: .destructive) {}.foregroundStyle(EnvInk.danger)
            }
            .controlSize(.small)
        }
    }

    private var noHost: some View {
        let entry = sample.noHost
        return VStack(alignment: .leading, spacing: 0) {
            columns
            Divider()
            line(entry, open: true)
            VStack(alignment: .leading, spacing: 10) {
                EnvNote(tone: .danger, text: "An API secret needs at least one host. With no host, no request can carry it.")
                HStack(spacing: 8) {
                    Text("Add a host").font(.system(size: TypeScale.detail)).foregroundStyle(EnvInk.secondary)
                    TextField("api.example.com", text: .constant("")).textFieldStyle(.roundedBorder).frame(width: 220)
                        .font(.system(size: TypeScale.body, design: .monospaced))
                    Text("or").font(.system(size: TypeScale.detail)).foregroundStyle(EnvInk.tertiary)
                    Button("Use for setup only") {}.buttonStyle(.borderedProminent)
                    Button("Put in the environment…") {}
                }
                .controlSize(.small)
                Text("Put in the environment lets the agent read the value. Use it only for tools that must read it themselves.")
                    .font(.system(size: TypeScale.caption)).foregroundStyle(EnvInk.secondary)
            }
            .padding(.leading, 28).padding(.trailing, 12).padding(.vertical, 12)
            .background(EnvInk.fill.opacity(0.6))
            Divider()
            ForEach(Array(sample.saved.prefix(3))) { entry in
                line(entry, open: false)
                Divider()
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(EnvInk.surface))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(EnvInk.line))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func approval(_ entry: EnvSecretsEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "clock.badge.exclamationmark").foregroundStyle(EnvInk.warning)
                Text("\(sample.pendingBy) asked to add a host · \(sample.pendingAt)").font(.system(size: TypeScale.detail, weight: .semibold))
            }
            HStack(spacing: 4) {
                Text("Hosts").font(.system(size: TypeScale.detail)).foregroundStyle(EnvInk.secondary).frame(width: 60, alignment: .leading)
                ForEach(entry.hosts, id: \.self) { EnvHostChip(host: $0) }  // visible-only: fixed sample list of at most 4 items
                EnvHostChip(host: sample.pendingHost, added: true)
            }
            Text("Until an admin approves, the secret goes only to api.stripe.com. Every host change is in the history.")
                .font(.system(size: TypeScale.caption)).foregroundStyle(EnvInk.secondary)
            HStack {
                Button { } label: { Label("Approve with Touch ID", systemImage: "touchid") }.buttonStyle(.borderedProminent)
                Button("Decline") {}
                Spacer()
                Text("Only admins see these buttons").font(.system(size: TypeScale.caption)).foregroundStyle(EnvInk.tertiary)
            }
            .controlSize(.small)
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 10) {
            EnvAuditTable(events: sample.audit)
            Text("Each use and each change is listed. The value itself is never logged.")
                .font(.system(size: TypeScale.caption)).foregroundStyle(EnvInk.secondary)
        }
    }

    private func revoke(_ entry: EnvSecretsEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Revoke \(entry.name) now?").font(.system(size: TypeScale.body, weight: .semibold))
            Text("It stops everywhere at once. \(sample.runningChats.count) running chats lose it now, and requests to api.stripe.com fail until you enter a new value.")
                .font(.system(size: TypeScale.detail)).foregroundStyle(EnvInk.secondary)
            HStack(spacing: 6) {
                ForEach(sample.runningChats, id: \.self) { chat in  // visible-only: fixed sample list of at most 4 items
                    Label(chat, systemImage: "bubble.left").font(.system(size: TypeScale.caption)).foregroundStyle(EnvInk.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(EnvInk.fill))
                }
            }
            HStack {
                Button("Cancel") {}
                Button(role: .destructive) {} label: { Label("Revoke with Touch ID", systemImage: "touchid") }.buttonStyle(.borderedProminent).tint(EnvInk.danger)
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(EnvInk.danger.opacity(0.5)))
    }

    private var scopes: some View {
        VStack(alignment: .leading, spacing: 10) {
            EnvNote(tone: .info, text: "Most specific wins: Chat, then Personal, then Team. Personal values never apply when a teammate drives your chat.")
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("Name").frame(width: 210, alignment: .leading)
                    Text("Used value").frame(width: 150, alignment: .leading)
                    Text("From").frame(width: 110, alignment: .leading)
                    Text("Also set in").frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: TypeScale.caption, weight: .semibold)).foregroundStyle(EnvInk.tertiary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                Divider()
                ForEach(sample.layers) { layer in
                    HStack(spacing: 0) {
                        Text(layer.name).font(EnvInk.monoStrong).frame(width: 210, alignment: .leading)
                        Text(layer.value(layer.winner) ?? "").font(EnvInk.mono).frame(width: 150, alignment: .leading)
                        EnvScopeTag(scope: layer.winner, strong: true).frame(width: 110, alignment: .leading)
                        HStack(spacing: 10) {
                            ForEach(EnvSecretsEntry.Scope.allCases.filter { $0 != layer.winner && layer.value($0) != nil }) { scope in
                                HStack(spacing: 4) {
                                    EnvScopeTag(scope: scope)
                                    Text(layer.value(scope) ?? "").font(.system(size: TypeScale.caption, design: .monospaced))
                                        .foregroundStyle(EnvInk.tertiary).strikethrough()
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    Divider()
                }
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(EnvInk.surface))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(EnvInk.line))
        }
    }

    private var request: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(EnvInk.secondary)
                Text("I need a Stripe key to create test refunds. I asked for STRIPE_RESTRICTED_KEY; I will only get a placeholder.")
                    .font(.system(size: TypeScale.body)).foregroundStyle(EnvInk.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield").foregroundStyle(EnvSecretsKind.apiSecret.tint)
                    Text("Secret request").font(.system(size: TypeScale.detail, weight: .semibold))
                    Text("from “\(sample.requestChat)”").font(.system(size: TypeScale.detail)).foregroundStyle(EnvInk.secondary)
                    Spacer()
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("Name").foregroundStyle(EnvInk.secondary)
                        Text(sample.requestName).font(EnvInk.monoStrong)
                    }
                    GridRow {
                        Text("Goes to").foregroundStyle(EnvInk.secondary)
                        HStack(spacing: 6) {
                            EnvHostChip(host: sample.requestHost)
                            Text("as Authorization: Bearer").font(.system(size: TypeScale.caption)).foregroundStyle(EnvInk.tertiary)
                        }
                    }
                    GridRow {
                        Text("Why").foregroundStyle(EnvInk.secondary)
                        Text(sample.requestReason)
                    }
                    GridRow {
                        Text("Value").foregroundStyle(EnvInk.secondary)
                        SecureField("Paste or type the value", text: .constant("")).textFieldStyle(.roundedBorder).frame(width: 320)
                    }
                    GridRow {
                        Text("Keep in").foregroundStyle(EnvInk.secondary)
                        Picker("Keep in", selection: .constant(EnvSecretsEntry.Scope.chat)) {
                            ForEach(EnvSecretsEntry.Scope.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 230)
                    }
                }
                .font(.system(size: TypeScale.detail))
                Text("The agent gets only the placeholder $\(sample.requestName). It never sees what you type, and nobody can read the value back after you save.")
                    .font(.system(size: TypeScale.caption)).foregroundStyle(EnvInk.secondary)
                HStack {
                    Spacer()
                    Button("Decline") {}
                    Button("Save secret") {}.buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(EnvInk.surface))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(EnvSecretsKind.apiSecret.tint.opacity(0.5)))
            .frame(maxWidth: 640, alignment: .leading)
        }
    }
}
#endif
