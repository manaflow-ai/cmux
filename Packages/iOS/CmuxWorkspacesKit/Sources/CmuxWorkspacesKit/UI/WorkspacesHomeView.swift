#if os(iOS)
import SwiftUI

/// The three candidate home designs. None uses a sidebar or a hamburger:
/// the home screen is the root of a navigation stack and a workspace is a push.
public enum WorkspacesDesign: String, CaseIterable, Identifiable, Sendable {
    /// Claude/ChatGPT recents: date-grouped list and a prompt box at the bottom.
    case recents
    /// Mail-style triage: Needs you, Running, Everything else, with previews.
    case triage
    /// Card grid with the last message on each card, like a tab overview.
    case cards

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .recents: "Recents"
        case .triage: "Triage"
        case .cards: "Cards"
        }
    }

    public var summary: String {
        switch self {
        case .recents: "Date-grouped list with a prompt box, like the Claude and ChatGPT apps."
        case .triage: "Grouped by what needs you, with filter chips and message previews."
        case .cards: "A two-column grid of cards that show each workspace's latest message."
        }
    }
}

public struct WorkspacesHomeView: View {
    let store: WorkspacesStore
    let design: WorkspacesDesign
    var onExitDemo: (() -> Void)?
    @State private var path: [String]

    /// `initialWorkspaceID` opens with that workspace already pushed.
    public init(store: WorkspacesStore, design: WorkspacesDesign, initialWorkspaceID: String? = nil, onExitDemo: (() -> Void)? = nil) {
        self.store = store
        self.design = design
        self.onExitDemo = onExitDemo
        _path = State(initialValue: initialWorkspaceID.map { [$0] } ?? [])
    }

    public var body: some View {
        NavigationStack(path: $path) {
            root
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { AccountMenu(onExitDemo: onExitDemo) }
                    ToolbarItem(placement: .topBarTrailing) { NewWorkspaceButton(store: store, open: open) }
                }
                .navigationDestination(for: String.self) { id in
                    WorkspaceDetailView(store: store, workspaceID: id) { next in
                        path = Array(path.dropLast()) + [next]
                    }
                }
        }
    }

    @ViewBuilder private var root: some View {
        switch design {
        case .recents: RecentsDesign(store: store, open: open)
        case .triage: TriageDesign(store: store, open: open)
        case .cards: CardsDesign(store: store, open: open)
        }
    }

    private func open(_ id: String) { path.append(id) }
}

/// Team name as the navigation title, with the team menu on it.
struct TeamTitle: ViewModifier {
    let store: WorkspacesStore

    func body(content: Content) -> some View {
        content
            .navigationTitle(store.team?.name ?? "Workspaces")
            .toolbarTitleMenu {
                Picker("Team", selection: Bindable(store).teamID) {
                    ForEach(store.teams) { Text($0.name).tag($0.id) }
                }
                Button("Invite to Team", systemImage: "person.badge.plus") {}
            }
    }
}

/// Line under the title: Mac presence, or connecting while cached rows show.
struct HomeStatusLine: View {
    let store: WorkspacesStore

    var body: some View {
        if store.phase == .connecting {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Connecting to your Macs…")
            }
            .font(.footnote).foregroundStyle(.secondary)
        } else {
            MacPresence(macs: store.macs)
        }
    }
}

/// Empty and no-match states that tell the truth about loading.
struct HomeEmptyState: View {
    let store: WorkspacesStore
    let query: String

    var body: some View {
        if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else if store.phase == .connecting {
            ProgressView("Loading workspaces…")
        } else {
            ContentUnavailableView("No workspaces yet", systemImage: "square.stack",
                                   description: Text("Start one below, or tap the pencil."))
        }
    }
}

extension WorkspacesStore {
    func isOffline(_ item: WorkspaceItem) -> Bool { mac(item.macID)?.isOnline == false }

    /// "feat-cnx-wireguard · MacBook Pro · 4m", or "Mac offline · 1d".
    func meta(_ item: WorkspaceItem) -> String {
        let age = grouping.shortAge(item.lastActivity)
        if isOffline(item) { return "Mac offline · \(age)" }
        return "\(item.branch) · \(mac(item.macID)?.name ?? "") · \(age)"
    }
}
#endif
