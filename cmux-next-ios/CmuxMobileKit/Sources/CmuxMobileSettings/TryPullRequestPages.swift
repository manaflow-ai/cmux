#if os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import CmuxSpinner
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// Settings > Developer > Try a Pull Request (DEBUG builds, so cmux Dev): the Macs that can
/// install a pull request's cmux Dev on this phone (their host lists `try-pr-v1`).
struct TryPullRequestMacsPage: View {
    let store: AppStore

    private var macs: [MacDevice] {
        MacRoster.acrossTeams(store.teams, activeTeamID: store.activeTeamID)
            .filter { store.macCapabilities[$0.id]?.contains(tryPullRequestCapability) == true }
    }

    var body: some View {
        List {
            Section {
                if macs.isEmpty {
                    Text("No connected Mac can install pull requests.").foregroundStyle(theme.colors.label2)
                }
                ForEach(macs) { mac in
                    NavigationLink(value: SettingsRoute.tryPullRequestMac(mac.id)) {
                        SettingsLabel("\(mac.name)", symbol: "laptopcomputer")
                    }
                }
            } footer: {
                Text("The Mac this iPhone is plugged into installs the pull request's cmux Dev over this app. On that Mac, link a cmux checkout's cmux-next-ios/scripts/try.sh to ~/.config/cmux/try.sh.")
            }
        }
        .settingsPage("Try a Pull Request")
    }
}

/// One Mac's open iPhone pull requests; a tap installs that head's cmux Dev.
struct TryPullRequestPage: View {
    let macID: String
    let store: AppStore
    @State private var model: TryPullRequestModel
    @State private var confirming: TryPullRequest?

    init(macID: String, store: AppStore, service: (any TryPullRequestService)?) {
        self.macID = macID
        self.store = store
        _model = State(initialValue: TryPullRequestModel(macID: macID, service: service))
    }

    var body: some View {
        List {
            installSection
            switch model.load {
            case .loading:
                Section { CmuxSpinner(label: Text("Loading pull requests…")) }
            case .failed(let message):
                Section { Text(verbatim: message).foregroundStyle(theme.colors.label2) }
            case .loaded(let list):
                Section {
                    if let error = list.error {
                        Text(verbatim: error).foregroundStyle(theme.colors.label2)
                    } else if list.prs.isEmpty {
                        Text("No open iPhone pull requests.").foregroundStyle(theme.colors.label2)
                    }
                    ForEach(list.prs) { pr in
                        Button { confirming = pr } label: { TryPullRequestRow(pr: pr) }
                            .disabled(model.installing)
                            .accessibilityIdentifier("settings.tryPullRequest.\(pr.number)")
                    }
                } footer: {
                    Text("Built: the build is ready and installs in about a minute. Not built: the Mac builds it first, which can take a while.")
                }
            }
        }
        .settingsPage("Pull Requests")
        .refreshable { await model.reload() }
        .task(id: store.macConnection[macID] == .connected) { await model.reload() }
        .confirmationDialog(
            confirming.map { "Install #\($0.number) on this iPhone?" } ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible,
            presenting: confirming
        ) { pr in
            Button("Install") { Task { await model.start(pr.number) } }
        } message: { _ in
            Text("cmux Dev closes and reopens as that pull request's build. Your sign-in and pairing stay.")
        }
    }

    @ViewBuilder private var installSection: some View {
        switch model.install {
        case .idle:
            EmptyView()
        case .running(let number, let lines):
            Section {
                CmuxSpinner(label: Text(verbatim: "Installing #\(number)…"))
                TryInstallLines(lines: lines)
            }
        case .finished(let number, let exit, let lines):
            Section {
                Text(verbatim: exit == 0 ? "#\(number) installed." : "#\(number) did not install (exit \(exit)).")
                TryInstallLines(lines: lines)
            }
        case .failed(let number, let message, let lines):
            Section {
                Text(verbatim: "#\(number): \(message)")
                TryInstallLines(lines: lines)
            }
        }
    }
}

private struct TryPullRequestRow: View {
    let pr: TryPullRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: "#\(pr.number)").font(theme.type.meta).foregroundStyle(theme.colors.label2)
                Text(verbatim: pr.title).foregroundStyle(theme.colors.label).lineLimit(2)
            }
            HStack(spacing: 6) {
                Text(verbatim: pr.build.label)
                    .foregroundStyle(pr.build.ready ? theme.colors.label : theme.colors.label3)
                if pr.draft { Text("Draft") }
                if !pr.author.isEmpty { Text(verbatim: pr.author) }
                if let updated = pr.updatedAt { Text(updated, style: .relative) }
            }
            .font(theme.type.meta)
            .foregroundStyle(theme.colors.label3)
            .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

private struct TryInstallLines: View {
    let lines: [String]

    var body: some View {
        if !lines.isEmpty {
            Text(verbatim: lines.joined(separator: "\n"))
                .font(.caption.monospaced())
                .foregroundStyle(theme.colors.label2)
                .lineLimit(TryPullRequestModel.keepLines)
        }
    }
}
#endif
