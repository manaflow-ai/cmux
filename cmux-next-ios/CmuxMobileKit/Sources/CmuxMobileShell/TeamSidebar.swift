#if os(iOS)
import CmuxMobileAuth
import CmuxMobileDesign
import CmuxMobileModel
import CmuxMobileSettings
import CmuxSpinner
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// The drawer's content (SPEC 3.3, with the product override): a "Teams"
/// header with a `+` menu (Create team, Join with invite link), the team list
/// with avatars and Mac presence dots, and Invite (the active team, never the
/// personal space) at the bottom trailing edge. Team switching only. Any other
/// team is invited from its row's context menu.
struct TeamSidebar: View {
    let store: AppStore
    let shell: ShellModel
    let sidebar: SidebarModel
    @State private var creatingTeam = false
    @State private var joiningTeam = false
    @State private var newTeamName = ""
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // The header names the list; no second "Teams" label.
                    Spacer().frame(height: 16)
                    ForEach(store.teams) { team in
                        row(team)
                    }
                    if store.teams.isEmpty, store.awaitsAccountData {
                        // Teams still loading: never "No teams".
                        CmuxSpinner(label: Text("Loading teams…"))
                            .padding(.horizontal, theme.metrics.sideMargin)
                            .padding(.vertical, 8)
                            .accessibilityIdentifier("sidebar.teams.loading")
                    } else if store.teams.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("No teams. Create one to share Macs and workspaces.")
                                .font(theme.type.rowSubtitle)
                                .foregroundStyle(theme.colors.label2)
                            PrimaryCapsule("Create team", systemImage: "plus", size: .inline) { creatingTeam = true }
                        }
                        .padding(.horizontal, theme.metrics.sideMargin)
                        .padding(.vertical, 8)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
            // The drawer's bottom toolbar: Invite at the trailing edge, over the
            // list's end, at the tab bar's line.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // The personal space is just you: nobody to invite.
                if let team = store.activeTeam, !team.isPersonalSpace {
                    HStack {
                        Spacer(minLength: 0)
                        inviteButton(team)
                    }
                    .padding(.horizontal, theme.metrics.sideMargin)
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(CmuxMobileBackdrop().ignoresSafeArea())
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
            // The pasted link stays until the join works (ShellModel.inviteLinkDraft).
            TextField("Invite link", text: Bindable(shell).inviteLinkDraft)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            Button("Cancel", role: .cancel) { shell.inviteLinkDraft = "" }
            Button("Join") { shell.joinTeam(inviteLink: shell.inviteLinkDraft) }
                .keyboardShortcut(.defaultAction)
        }
    }

    /// "Teams" and the drawer's add menu. The title names what the drawer
    /// switches; the brand wordmark it replaced said nothing the app icon
    /// doesn't.
    private var header: some View {
        HStack(spacing: 8) {
            Text("Teams")
                .font(theme.type.sidebarTitle)
                .foregroundStyle(theme.colors.label)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
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

    /// A glass capsule, "Invite", 44 pt tall like the drawer's `+`; it acts on
    /// the selected team and its label names that team. At
    /// accessibility text sizes the glyph alone, in a circle, so the title
    /// keeps its room. While the invite link is being made the glyph is a
    /// spinner and the button does nothing.
    private func inviteButton(_ team: Team) -> some View {
        Button {
            shell.invite(to: team)
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    if shell.isFetchingInvite {
                        CmuxSpinner()
                    } else {
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: theme.metrics.glassSymbol, weight: .regular))
                    }
                }
                .frame(width: 24, height: 24)
                if !typeSize.isAccessibilitySize {
                    Text("Invite")
                        .lineLimit(1)
                }
            }
            .font(theme.type.rowTitle)
            .foregroundStyle(theme.colors.label)
            .padding(.horizontal, typeSize.isAccessibilitySize ? 0 : 14)
            .frame(minWidth: 44, minHeight: 44)
            // Its natural width, always: the header row gives way at the title
            // (which scales down), never by truncating "Invite".
            .fixedSize()
            .contentShape(.capsule)
        }
        .buttonStyle(.cmuxPressGlass)
        .glassEffect(.regular.interactive(), in: .capsule)
        .disabled(shell.isFetchingInvite)
        .accessibilityLabel("Invite to \(team.name)")
        .accessibilityIdentifier("sidebar.invite")
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
            .animation(theme.motion.snap.animation.unlessReduceMotion, value: selected)
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
