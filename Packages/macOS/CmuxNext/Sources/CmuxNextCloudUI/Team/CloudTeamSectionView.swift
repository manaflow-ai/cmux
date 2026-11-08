public import CmuxNextActions
import CmuxNextDesign
public import SwiftUI

/// The sidebar's Team section (lane D): the team's Cloud workspaces and chats under one of four
/// filters, each row with its follow (eye) toggle and a menu with Reassign To, Copy Link and
/// Archive. It draws ``CloudTeamSessionStore`` and runs every change as an action (`perform`), so
/// a click does what `cmux cloud follow|reassign|copy-session-link|archive-session` does.
public struct CloudTeamSectionView: View {
    /// Runs a catalog action with these arguments as the person's run.
    public typealias Perform = @MainActor (ActionID, [String: ActionValue]) -> Void

    @Bindable var store: CloudTeamSessionStore
    let palette: AutomationsPalette
    let perform: Perform
    let open: @MainActor (CloudTeamSession) -> Void

    public init(store: CloudTeamSessionStore, palette: AutomationsPalette, perform: @escaping Perform,
                open: @escaping @MainActor (CloudTeamSession) -> Void) {
        self.store = store
        self.palette = palette
        self.perform = perform
        self.open = open
    }

    /// Rows a section shows before it scrolls.
    public static let maxRows = 8
    public static let rowHeight: CGFloat = 26
    public static let filterHeight: CGFloat = 26

    /// The section's height for the current rows (the sidebar asks before it lays out).
    @MainActor public static func height(for store: CloudTeamSessionStore) -> CGFloat {
        filterHeight + rowHeight * CGFloat(max(1, min(maxRows, store.sessions.count)))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            filters.frame(height: Self.filterHeight)
            if store.sessions.isEmpty {
                Text(placeholder).font(palette.caption).foregroundStyle(palette.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading).padding(.horizontal, 8)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(store.sessions) { row in
                            CloudTeamSessionRow(row: row, palette: palette, members: store.members,
                                                perform: perform, open: open)
                                .frame(height: Self.rowHeight)
                        }
                    }
                }
                .scrollIndicators(.automatic)
            }
        }
        .task {
            await store.refresh()
            await loadMembers()
        }
    }

    private var placeholder: String {
        if let error = store.listError { return error.message }
        return store.isLoading ? CloudTeamStrings.loading : CloudTeamStrings.empty(store.filter)
    }

    private var filters: some View {
        HStack(spacing: 2) {
            ForEach(CloudTeamSessionStore.Filter.allCases, id: \.self) { filter in
                let selected = store.filter == filter
                // The filter is this view's state: the store shows the rows it has for it at once, then lists.
                // task-owner: one list of the picked filter; a later pick drops its reply.
                Button { Task { await store.select(filter) } } label: {
                    Text(CloudTeamStrings.filterTitle(filter)).font(palette.caption).lineLimit(1)
                        .foregroundStyle(selected ? palette.text : palette.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(selected ? palette.selection : .clear, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
    }

    private func loadMembers() async {
        guard store.members.isEmpty else { return }
        _ = try? await store.loadMembers()
    }
}

/// One team Cloud session: title, who it is assigned to and what it is doing, the eye toggle.
struct CloudTeamSessionRow: View {
    let row: CloudTeamSession
    let palette: AutomationsPalette
    let members: [CloudTeamMember]
    let perform: CloudTeamSectionView.Perform
    let open: @MainActor (CloudTeamSession) -> Void
    @State private var hovering = false

    private var session: [String: ActionValue] { ["session": .string(row.key)] }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: row.kind == .chat ? "bubble.left" : "square.stack").foregroundStyle(palette.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.title.isEmpty ? row.session : row.title).font(palette.body).foregroundStyle(palette.text).lineLimit(1)
                Text(subtitle).font(palette.caption).foregroundStyle(activityColor).lineLimit(1)
            }
            Spacer(minLength: 0)
            if row.canFollow {
                Button { perform(row.following ? "cloud.team.unfollow" : "cloud.team.follow", session) } label: {
                    Image(systemName: row.following ? "eye.fill" : "eye")
                        .foregroundStyle(row.following ? palette.text : palette.tertiary)
                }
                .buttonStyle(.plain)
                .opacity(row.following || hovering ? 1 : 0)
                .help(row.following ? CloudTeamStrings.unfollow : CloudTeamStrings.follow)
                .accessibilityLabel(row.following ? CloudTeamStrings.unfollow : CloudTeamStrings.follow)
            }
        }
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .background(hovering ? palette.hover : .clear)
        .onHover { hovering = $0 }
        .onTapGesture { open(row) }
        .contextMenu { menu }
    }

    private var subtitle: String {
        let who = row.assignedToYou ? nil : (row.assigneeName ?? row.assignee)
        let doing = CloudTeamStrings.activity(row.activity, machine: row.machineState)
        guard let who else { return doing }
        return "\(CloudTeamStrings.assignedTo(who)) · \(doing)"
    }

    private var activityColor: Color {
        switch row.activity {
        case "needs_attention": palette.attention
        case "working": palette.text
        default: palette.secondary
        }
    }

    @ViewBuilder private var menu: some View {
        if row.canFollow {
            Button(row.following ? CloudTeamStrings.unfollow : CloudTeamStrings.follow) {
                perform(row.following ? "cloud.team.unfollow" : "cloud.team.follow", session)
            }
        }
        if row.canReassign {
            Menu(CloudTeamStrings.reassign) {
                let others = members.filter { $0.canBeAssigned && $0.user != row.assignee }
                if others.isEmpty {
                    Text(CloudTeamStrings.noMembers)
                }
                ForEach(others) { member in
                    Button(member.name) { perform("cloud.team.reassign", session.merging(["to": .string(member.user)]) { $1 }) }
                }
            }
        }
        // No default shortcut: Cmd-Shift-C is the browser's Copy URL.
        Button(CloudTeamStrings.copyLink) { perform("cloud.team.copyLink", session) }
        if row.canArchive {
            Divider()
            Button(row.archived ? CloudTeamStrings.restore : CloudTeamStrings.archive) {
                perform("cloud.team.archive", session.merging(["archived": .bool(!row.archived)]) { $1 })
            }
        }
    }
}
