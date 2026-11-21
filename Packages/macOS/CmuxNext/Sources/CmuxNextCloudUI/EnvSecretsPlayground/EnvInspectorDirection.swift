#if DEBUG
import CmuxNextDesign
import SwiftUI

/// DEBUG ONLY (Environment Secrets Playground), direction 3 "Inspector": a source list grouped by type
/// on the left, the selected value's form on the right, as a Mac settings pane; approvals, history
/// and revoke are sections and sheets of the detail, never inline in the list.
struct EnvInspectorDirection: View {
    @Bindable var model: EnvSecretsPlaygroundModel

    private var sample: EnvSecretsSample { model.sample }

    var body: some View {
        if model.scene == .cli {
            EnvTerminalFrames()
        } else {
            HStack(spacing: 0) {
                sidebar.frame(width: 260)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
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

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(sample.environment).font(.system(size: TypeScale.body, weight: .semibold))
                Picker("Scope", selection: $model.scope) {
                    ForEach(EnvSecretsEntry.Scope.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            .padding(12)
            Divider()
            if model.scene == .scopes {
                scopeList
            } else if rows.isEmpty {
                Text("No values").font(.system(size: TypeScale.detail)).foregroundStyle(EnvInk.tertiary).padding(12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        group("Secrets", rows.filter { $0.kind != .variable })
                        group("Variables", rows.filter { $0.kind == .variable })
                    }
                    .padding(.vertical, 6)
                }
            }
            Spacer(minLength: 0)
            Divider()
            HStack(spacing: 2) {
                Button { } label: { Image(systemName: "plus").frame(width: 22, height: 22) }.accessibilityLabel("Add value")  // plus-button-allow: a prototype glyph inside a DEBUG playground
                Button { } label: { Image(systemName: "doc.on.clipboard").frame(width: 22, height: 22) }.accessibilityLabel("Paste .env")
                Spacer()
            }
            .buttonStyle(.cmuxPressFill).padding(6)
        }
        .background(EnvInk.canvas)
    }

    @ViewBuilder private func group(_ title: String, _ entries: [EnvSecretsEntry]) -> some View {
        if !entries.isEmpty {
            Text(title).font(.system(size: TypeScale.caption, weight: .semibold)).foregroundStyle(EnvInk.tertiary)
                .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 2)
            ForEach(entries) { entry in
                listRow(entry, selected: entry.name == selected)
            }
        }
    }

    private func listRow(_ entry: EnvSecretsEntry, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: entry.kind.symbol).font(.system(size: TypeScale.detail))
                .foregroundStyle(selected ? Color.white : entry.kind.tint).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(.system(size: TypeScale.detail, weight: .semibold, design: .monospaced)).lineLimit(1)
                Text(subtitle(entry)).font(.system(size: TypeScale.caption)).lineLimit(1)
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : EnvInk.secondary)
            }
            Spacer(minLength: 0)
            if marker(entry) {
                Circle().fill(selected ? Color.white : EnvInk.warning).frame(width: 7, height: 7)
            }
        }
        .foregroundStyle(selected ? Color.white : EnvInk.text)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? Color.accentColor : .clear))
        .padding(.horizontal, 6)
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

    private var scopeList: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(sample.layers) { layer in
                HStack(spacing: 8) {
                    Image(systemName: layer.winner.symbol).font(.system(size: TypeScale.caption)).frame(width: 16)
                        .foregroundStyle(layer.name == selected ? Color.white : EnvInk.secondary)
                    Text(layer.name).font(.system(size: TypeScale.detail, weight: .semibold, design: .monospaced))
                    Spacer()
                    Text(layer.winner.title).font(.system(size: TypeScale.caption))
                        .foregroundStyle(layer.name == selected ? Color.white.opacity(0.8) : EnvInk.secondary)
                }
                .foregroundStyle(layer.name == selected ? Color.white : EnvInk.text)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(layer.name == selected ? Color.accentColor : .clear))
                .padding(.horizontal, 6)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        switch model.scene {
        case .empty: emptyDetail
        case .paste: pasteDetail
        case .saved: form(sample.saved[0], tab: 0)
        case .noHost: noHostDetail
        case .approval: form(sample.saved[0], tab: 0, pending: true)
        case .audit: form(sample.saved[0], tab: 1)
        case .revoke: form(sample.saved[0], tab: 0).overlay(alignment: .top) { revokeSheet }
        case .scopes: scopesDetail
        case .request: requestDetail
        case .cli: EnvTerminalFrames()
        }
    }

    private var emptyDetail: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "key.horizontal").font(.system(size: TypeScale.heading)).foregroundStyle(EnvInk.tertiary)
            Text("No values in \(sample.environment)").font(.system(size: TypeScale.title, weight: .semibold))
            Text("Paste a .env file to start. You check every line and its type before cmux saves anything.")
                .font(.system(size: TypeScale.detail)).foregroundStyle(EnvInk.secondary).multilineTextAlignment(.center).frame(maxWidth: 340)
            HStack {
                Button("Paste .env") {}.buttonStyle(.borderedProminent)
                Button("Add value") {}
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: TypeScale.caption, weight: .semibold)).foregroundStyle(EnvInk.secondary)
            VStack(alignment: .leading, spacing: 10, content: content)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(EnvInk.surface))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(EnvInk.line))
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.system(size: TypeScale.detail)).foregroundStyle(EnvInk.secondary).frame(width: 90, alignment: .trailing)
            content()
            Spacer(minLength: 0)
        }
    }

    private func detailHeader(_ entry: EnvSecretsEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.kind.symbol).font(.system(size: TypeScale.heading)).foregroundStyle(entry.kind.tint)
                .frame(width: 34, height: 34).background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(entry.kind.tint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.system(size: TypeScale.title, weight: .semibold, design: .monospaced))
                Text(entry.kind.title).font(.system(size: TypeScale.detail)).foregroundStyle(EnvInk.secondary)
            }
            Spacer()
        }
    }

    private func typeRadio(_ current: EnvSecretsKind, entry: EnvSecretsEntry?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(EnvSecretsKind.allCases) { kind in
                Button {
                    if let entry { model.setKind(kind, for: entry) }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: kind == current ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(kind == current ? Color.accentColor : EnvInk.tertiary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(kind.title).font(.system(size: TypeScale.detail, weight: .semibold)).foregroundStyle(EnvInk.text)
                            Text(kind.promise).font(.system(size: TypeScale.caption)).foregroundStyle(EnvInk.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.cmuxPressFill)
            }
        }
    }

    private var pasteDetail: some View {
        let entry = model.review.first { $0.name == "LEGACY_LICENSE" } ?? model.review[0]
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Review 7 pasted lines").font(.system(size: TypeScale.title, weight: .semibold))
                    Spacer()
                    Text("1 of 7 needs care").font(.system(size: TypeScale.caption)).foregroundStyle(EnvInk.warning)
                }
                detailHeader(entry)
                section("Type") {
                    typeRadio(entry.kind, entry: entry)
                    if let reason = entry.reason { Text("Picked because: \(reason).").font(.system(size: TypeScale.caption)).foregroundStyle(EnvInk.tertiary) }
                }
                if entry.kind == .envSecret {
                    EnvNote(tone: .warning, text: "The agent and any code it runs can read and print this value. cmux masks it in the terminal and the transcript as •••• (\(entry.name)). A team environment needs an admin to allow it.")
                }
                HStack {
                    Button("Previous") {}
                    Button("Next") {}
                    Spacer()
                    Button("Cancel") {}
                    Button("Save 7 values") {}.buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
        }
    }

    private func form(_ entry: EnvSecretsEntry, tab: Int, pending: Bool = false) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                detailHeader(entry)
                Picker("", selection: .constant(tab)) {
                    Text("Details").tag(0)
                    Text("History").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                if tab == 1 {
                    section("Every use and change") {
                        EnvAuditTable(events: sample.audit)
                        Text("The value itself is never logged.").font(.system(size: TypeScale.caption)).foregroundStyle(EnvInk.tertiary)
                    }
                } else {
                    if pending { pendingSection(entry) }
                    section("Value") {
                        field("Value") {
                            Text("•••• \(entry.last4)").font(EnvInk.mono)
                            Button("Enter new value…") {}.controlSize(.small)
                        }
                        field("") { Text("Write-only. Nobody can read it back, not even an admin: there is no Reveal, Copy or Export.").font(.system(size: TypeScale.caption)).foregroundStyle(EnvInk.tertiary) }
                        field("Set by") { EnvProvenance(entry: entry) }
                    }
                    section("Where it goes") {
                        field("Hosts") {
                            HStack(spacing: 4) { ForEach(entry.hosts, id: \.self) { EnvHostChip(host: $0) } }  // visible-only: fixed sample list of at most 4 items
                        }
                        field("Sent as") {
                            Menu(entry.delivery?.title ?? "") {
                                ForEach(EnvSecretsEntry.Delivery.choices, id: \.title) { Button($0.title) {} }  // visible-only: fixed sample list of at most 4 items
                            }
                            .fixedSize()
                        }
                        field("") { Text(EnvSecretsKind.apiSecret.promise).font(.system(size: TypeScale.caption)).foregroundStyle(EnvInk.secondary) }
                    }
                    HStack {
                        Spacer()
                        Button("Revoke now…", role: .destructive) {}.foregroundStyle(EnvInk.danger)
                    }
                }
            }
            .padding(20)
        }
    }

    private func pendingSection(_ entry: EnvSecretsEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "touchid").font(.system(size: TypeScale.heading)).foregroundStyle(EnvInk.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Host change waiting for an admin").font(.system(size: TypeScale.body, weight: .semibold))
                    Text("\(sample.pendingBy) asked to add \(sample.pendingHost) · \(sample.pendingAt)").font(.system(size: TypeScale.detail)).foregroundStyle(EnvInk.secondary)
                }
            }
            HStack(spacing: 4) {
                ForEach(entry.hosts, id: \.self) { EnvHostChip(host: $0) }  // visible-only: fixed sample list of at most 4 items
                EnvHostChip(host: sample.pendingHost, added: true)
            }
            Text("Until an admin approves on a Mac with Touch ID, the secret goes only to api.stripe.com.")
                .font(.system(size: TypeScale.caption)).foregroundStyle(EnvInk.secondary)
            HStack {
                Button { } label: { Label("Approve with Touch ID", systemImage: "touchid") }.buttonStyle(.borderedProminent)
                Button("Decline") {}
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(EnvInk.warning.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(EnvInk.warning.opacity(0.45)))
    }

    private var noHostDetail: some View {
        let entry = sample.noHost
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                detailHeader(entry)
                EnvNote(tone: .danger, text: "This API secret has no host, so no request can carry it. Add a host, or choose another type.")
                section("Where it goes") {
                    field("Hosts") {
                        TextField("api.example.com", text: .constant("")).textFieldStyle(.roundedBorder)
                            .font(.system(size: TypeScale.body, design: .monospaced)).frame(width: 240)
                    }
                }
                section("Or use it another way") {
                    Button { } label: {
                        Label("Use for setup only", systemImage: EnvSecretsKind.setupSecret.symbol)
                    }
                    .buttonStyle(.borderedProminent)
                    Text(EnvSecretsKind.setupSecret.promise).font(.system(size: TypeScale.caption)).foregroundStyle(EnvInk.secondary)
                    Divider()
                    Button { } label: {
                        Label("Put in the environment…", systemImage: EnvSecretsKind.envSecret.symbol)
                    }
                    Text(EnvSecretsKind.envSecret.promise).font(.system(size: TypeScale.caption)).foregroundStyle(EnvInk.warning)
                }
            }
            .padding(20)
        }
    }

    private var revokeSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "xmark.octagon.fill").font(.system(size: TypeScale.heading)).foregroundStyle(EnvInk.danger)
            Text("Revoke STRIPE_SECRET_KEY now?").font(.system(size: TypeScale.field, weight: .semibold))
            Text("It stops everywhere at once. \(sample.runningChats.count) running chats lose it now. Requests to api.stripe.com fail until you enter a new value.")
                .font(.system(size: TypeScale.detail)).foregroundStyle(EnvInk.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") {}
                Button(role: .destructive) {} label: { Label("Revoke with Touch ID", systemImage: "touchid") }.buttonStyle(.borderedProminent).tint(EnvInk.danger)
            }
        }
        .padding(18)
        .frame(width: 380)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(EnvInk.canvas)
            .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(EnvInk.line))
        .padding(.top, 24)
    }

    private var scopesDetail: some View {
        let layer = sample.layers.first { $0.name == "REGION" } ?? sample.layers[0]
        let log = sample.layers.first { $0.name == "LOG_LEVEL" } ?? sample.layers[0]
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Where each value comes from").font(.system(size: TypeScale.title, weight: .semibold))
                Text("Chat wins over Personal, Personal wins over Team. Personal values never apply when a teammate drives your chat.")
                    .font(.system(size: TypeScale.detail)).foregroundStyle(EnvInk.secondary)
                stack(layer)
                stack(log)
            }
            .padding(20)
        }
    }

    private func stack(_ layer: EnvSecretsSample.Layer) -> some View {
        section(layer.name) {
            ForEach(Array(EnvSecretsEntry.Scope.allCases.reversed())) { scope in  // visible-only: the three scopes
                HStack(spacing: 10) {
                    EnvScopeTag(scope: scope, strong: scope == layer.winner).frame(width: 90, alignment: .leading)
                    if let value = layer.value(scope) {
                        Text(value).font(EnvInk.mono).strikethrough(scope != layer.winner)
                            .foregroundStyle(scope == layer.winner ? EnvInk.text : EnvInk.tertiary)
                    } else {
                        Text("Not set").font(.system(size: TypeScale.detail)).foregroundStyle(EnvInk.tertiary)
                    }
                    Spacer()
                    if scope == layer.winner {
                        Text("Used").font(.system(size: TypeScale.caption, weight: .semibold)).foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Color.accentColor.opacity(0.14)))
                    }
                }
                Text(scope.caption).font(.system(size: TypeScale.caption)).foregroundStyle(EnvInk.tertiary).padding(.leading, 100)
            }
        }
    }

    private var requestDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "lock.shield").font(.system(size: TypeScale.heading)).foregroundStyle(EnvSecretsKind.apiSecret.tint)
                        .frame(width: 34, height: 34)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(EnvSecretsKind.apiSecret.tint.opacity(0.14)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sample.requestName).font(.system(size: TypeScale.title, weight: .semibold, design: .monospaced))
                        Text("Asked by an agent in “\(sample.requestChat)”").font(.system(size: TypeScale.detail)).foregroundStyle(EnvInk.secondary)
                    }
                }
                section("Request") {
                    field("Why") { Text(sample.requestReason).font(.system(size: TypeScale.detail)).fixedSize(horizontal: false, vertical: true) }
                    field("Hosts") { EnvHostChip(host: sample.requestHost) }
                    field("Sent as") { Text("Authorization: Bearer").font(EnvInk.mono) }
                }
                section("Value") {
                    field("Value") {
                        SecureField("Type or paste the value", text: .constant("")).textFieldStyle(.roundedBorder).frame(width: 300)
                    }
                    field("") {
                        Text("Only you can fill this. The agent gets the placeholder $\(sample.requestName) and never the value.")
                            .font(.system(size: TypeScale.caption)).foregroundStyle(EnvInk.secondary)
                    }
                }
                section("Keep it in") {
                    ForEach(Array(EnvSecretsEntry.Scope.allCases.reversed())) { scope in  // visible-only: the three scopes
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: scope == .chat ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(scope == .chat ? Color.accentColor : EnvInk.tertiary)
                            VStack(alignment: .leading, spacing: 1) {
                                EnvScopeTag(scope: scope, strong: scope == .chat)
                                Text(scope == .team ? "Needs an admin's Touch ID." : scope.caption)
                                    .font(.system(size: TypeScale.caption)).foregroundStyle(EnvInk.secondary)
                            }
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Decline") {}
                    Button("Save secret") {}.buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
        }
    }
}
#endif
