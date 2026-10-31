#if os(iOS)
import CmuxMobileAuth
import CmuxMobileDesign
import CmuxMobileModel
import CmuxMobileSettings
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// The drawer's content (SPEC 3.3, with the product override): a "cmux" header
/// with a `+` menu (Create team, Join with invite link), the team list with
/// avatars and Mac presence dots, and "Invite to team". Team switching only.
struct TeamSidebar: View {
    let store: AppStore
    let shell: ShellModel
    let sidebar: SidebarModel
    @State private var creatingTeam = false
    @State private var joiningTeam = false
    @State private var newTeamName = ""
    @State private var inviteLink = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // A label only when there is a list to label.
                    if store.teams.count > 1 {
                        // At the team names' x, past the avatar column (SidebarTeamRow.textLeading).
                        Text("Teams")
                            .font(theme.type.meta)
                            .foregroundStyle(theme.colors.label2)
                            .padding(.leading, SidebarTeamRow.textLeading)
                            .padding(.trailing, theme.metrics.sideMargin)
                            .padding(.top, 24)
                            .padding(.bottom, 6)
                    } else {
                        Spacer().frame(height: 16)
                    }
                    ForEach(store.teams) { team in
                        row(team)
                    }
                    if store.teams.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("No teams. Create one to share Macs and workspaces.")
                                .font(theme.type.rowSubtitle)
                                .foregroundStyle(theme.colors.label2)
                            PrimaryCapsule("Create team", systemImage: "plus", size: .inline) { creatingTeam = true }
                        }
                        .padding(.horizontal, theme.metrics.sideMargin)
                        .padding(.vertical, 8)
                    }
                    // The personal space is just you: nobody to invite.
                    if let team = store.activeTeam, !team.isPersonalSpace {
                        inviteRow
                            .padding(.top, 4)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.colors.bg.color.ignoresSafeArea())
        .alert("Create team", isPresented: $creatingTeam) {
            TextField("Team name", text: $newTeamName)
                // Names and prompts are code-like: no autocorrect, no capitals (full verify D5).
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Cancel", role: .cancel) { newTeamName = "" }
            Button("Create") { shell.createTeam(named: newTeamName); newTeamName = "" }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("Teams share Macs and workspaces.")
        }
        .alert("Join with invite link", isPresented: $joiningTeam) {
            TextField("Invite link", text: $inviteLink)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            Button("Cancel", role: .cancel) { inviteLink = "" }
            Button("Join") { shell.joinTeam(inviteLink: inviteLink); inviteLink = "" }
                .keyboardShortcut(.defaultAction)
        }
    }

    private var header: some View {
        HStack {
            Text(verbatim: "cmux")
                .font(theme.type.sidebarTitle)
                .foregroundStyle(theme.colors.label)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Menu {
                Button("Create team", systemImage: "person.2.badge.plus") { creatingTeam = true }
                Button("Join with invite link", systemImage: "link") { joiningTeam = true }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: theme.metrics.glassSymbol, weight: .regular))
                    .foregroundStyle(theme.colors.label)
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Add team")
        }
        .padding(.horizontal, theme.metrics.sideMargin)
        .padding(.top, 0)
    }

    private func row(_ team: Team) -> some View {
        let presence = team.macDots(limit: theme.metrics.macDotLimit)
        let selected = team.id == store.activeTeamID
        return Button {
            shell.switchTeam(to: team.id)
        } label: {
            SidebarTeamRow(
                name: team.name,
                colorHex: team.appearance.colorHex,
                emoji: team.appearance.emoji,
                transparent: team.appearance.isTransparent,
                dots: presence.dots,
                overflow: presence.overflow,
                onlineCount: team.listedMacs.filter(\.isOnline).count,
                isSelected: selected
            )
            .animation(theme.motion.snap.animation, value: selected)
        }
        .buttonStyle(SidebarRowStyle())
        .padding(.horizontal, theme.metrics.selectedRowInset)
        .contextMenu {
            Button("Change color and icon", systemImage: "paintpalette") { shell.editingTeam = team }
            if !team.isPersonalSpace {
                Button("Invite to team", systemImage: "person.badge.plus") { shell.invite(to: team) }
            }
            Button("Copy team name", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = team.name
                theme.haptics.copy()
            }
        }
    }

    private var inviteRow: some View {
        Button {
            if let team = store.activeTeam { shell.invite(to: team) }
        } label: {
            // Same columns as the team rows: the glyph centered in the 36 pt
            // avatar column, the title at the team name's x.
            HStack(spacing: SidebarTeamRow.avatarGap) {
                ZStack {
                    if shell.isFetchingInvite {
                        ProgressView()
                    } else {
                        Image(systemName: "person.badge.plus").font(.system(size: 17))
                    }
                }
                .frame(width: theme.metrics.teamAvatar)
                Text("Invite to team").font(theme.type.rowTitle)
                Spacer()
            }
            .foregroundStyle(theme.colors.label)
            .padding(.horizontal, theme.metrics.sideMargin - theme.metrics.selectedRowInset)
            .frame(height: theme.metrics.sidebarRowPitch)
            .contentShape(.rect)
        }
        .buttonStyle(SidebarRowStyle())
        .padding(.horizontal, theme.metrics.selectedRowInset)
        .disabled(store.activeTeam == nil)
    }
}

/// Pressed rows get `fillPressed` behind them.
private struct SidebarRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: theme.metrics.selectedRowRadius, style: .continuous)
                    .fill(theme.colors.fillPressed)
                    .opacity(configuration.isPressed ? 1 : 0)
            }
    }
}
#endif
