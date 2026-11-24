#if os(iOS)
import CmuxMobileAgentChat
import CmuxMobileChief
import CmuxMobileDesign
import CmuxMobileModel
import CmuxMobileWorkspaces
import CmuxMobileTerminal
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// Leading toolbar item every root tab shares: the glass `line.3.horizontal`
/// circle that opens the team sidebar.
struct SidebarToolbarItem: ToolbarContent {
    let sidebar: SidebarModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Teams", systemImage: "line.3.horizontal") { sidebar.open() }
                .accessibilityLabel("Teams")
        }
    }
}

/// Centered toolbar title in `screenTitle`.
struct ScreenTitle: ToolbarContent {
    let title: LocalizedStringKey

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Text(title).font(theme.type.screenTitle).foregroundStyle(theme.colors.label)
        }
    }
}

struct HomeScreen: View {
    let shell: ShellModel
    @Environment(\.shellWindowLayout) private var layout

    var body: some View {
        @Bindable var shell = shell
        ListDetailSplit(layout: layout) {
            // Two-pane: the chats beside the open one, in a stack of their own for the title bar.
            NavigationStack { conversations }
        } detail: {
            NavigationStack(path: $shell.homePath) {
                Group {
                    if layout.twoPane {
                        DetailPlaceholder(title: "Pick a chat", systemImage: "bubble.left.and.bubble.right")
                    } else {
                        conversations
                    }
                }
                .agentChatDestinations()
            }
        }
    }

    private var conversations: some View {
        ConversationsHome(store: shell.store, macFilter: shell.macFilter,
                          reconnect: shell.live.map { live in { macID in await live.reconnectFeed(macID: macID) } },
                          selectMac: shell.live.map { live in { live.select(macID: $0) } },
                          inviteToTeam: { email in
                              guard let team = shell.store.activeTeam else { return }
                              shell.sendInvite(email: email, to: team)
                          }, open: { route in
            // Two-pane: a chat replaces the open one beside the list instead of stacking on it.
            if layout.twoPane { shell.homePath = NavigationPath() }
            if let chief = route.chiefRoute {
                shell.homePath.append(chief)
            } else if case let .agent(destination) = route {
                shell.homePath.append(destination)
            } else if case let .mac(conversation) = route {
                shell.homePath.append(conversation)
            } else if case let .cloud(conversation) = route {
                shell.homePath.append(conversation)
            }
        }) {
            SidebarToolbarItem(sidebar: shell.sidebar)
            ToolbarItem(placement: .topBarTrailing) {
                Button("Cloud chats", systemImage: "cloud") {
                    shell.cloudChats = ShellModel.CloudChatsPresentation(attention: nil)
                }
            }
        }
    }
}

struct WorkspacesScreen: View {
    let shell: ShellModel
    @Environment(\.shellWindowLayout) private var layout

    var body: some View {
        @Bindable var shell = shell
        ListDetailSplit(layout: layout) {
            // Two-pane: the workspaces beside the open one, in a stack of their own for the title bar.
            NavigationStack {
                workspaces
                    .toolbar { SidebarToolbarItem(sidebar: shell.sidebar) }
            }
        } detail: {
            NavigationStack(path: $shell.workspacesPath) {
                Group {
                    if layout.twoPane {
                        DetailPlaceholder(title: "Pick a workspace", systemImage: "square.stack.3d.up")
                    } else {
                        workspaces
                            .toolbar {
                                // WorkspacesList owns the title and the Mac chip row.
                                SidebarToolbarItem(sidebar: shell.sidebar)
                            }
                    }
                }
                .navigationDestination(for: Workspace.self) { ws in
                    WorkspaceScreen(store: shell.store, workspaceID: ws.id, terminal: shell.terminalTabs, creator: shell.creator,
                                    openWorkspace: { shell.show(workspace: $0) }, screenSharing: shell.screenSharing)
                }
                .cmuxMobileBanner(workspacesBanner, retry: shell.bannerHasAction ? { shell.bannerAction() } : nil)
            }
        }
    }

    /// The shell's banner, less a link chip ("Mac offline", "Can't reach") while the list's Mac
    /// panel says the same with its last-seen time and Retry (cmux#52200 walk: the chip sat over
    /// the panel's icon). A banner with words to read (pairing, signed out) still shows.
    private var workspacesBanner: ConnectionBannerState? {
        guard let banner = shell.banner else { return nil }
        if banner.chip != nil, shell.workspacesPath.isEmpty, shell.workspacesMacPanelShown { return nil }
        return banner
    }

    private var workspaces: some View {
        WorkspacesList(
                store: shell.store, creator: shell.creator, accountEmail: shell.auth.user?.email,
                reconnect: shell.live.map { live in
                    { macID in live.recover(macID: macID) }
                },
                linking: shell.live.map { live in
                    MacLinking(link: { live.select(macID: $0) }, canLink: { live.canLink(macID: $0) },
                               isLinkTarget: { live.isLinked(macID: $0) })
                },
                refresh: shell.live.map { live in { await live.refreshWorkspaces() } } ?? Self.rigRefresh,
                retryLoad: { await shell.retryWorkspaces() },
                switchTeam: { shell.switchTeam(to: $0) },
                openAccount: {
                    shell.tab = .settings
                    shell.settingsPath = [.account]
                },
                filter: shell.macFilter,
                macPanelShown: { shown in if shell.workspacesMacPanelShown != shown { shell.workspacesMacPanelShown = shown } }
            ) { workspace in
                // Two-pane: a workspace replaces the open one beside the list instead of stacking on it.
                if layout.twoPane { shell.workspacesPath = [workspace] } else { shell.workspacesPath.append(workspace) }
            }
            .background(theme.colors.bg.color.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
    }

    /// Mock mode has no live refresh; the pull-to-refresh rig gives the list one
    /// (`CMUX_MOBILE_LIST_REFRESH_SECONDS`, DEBUG and Demo builds only).
    private static var rigRefresh: (() async -> Void)? {
        #if DEBUG
        ListStressSettings.shared.refreshSeconds.map { seconds in { try? await Task.sleep(for: .seconds(seconds)) } }
        #else
        nil
        #endif
    }
}

#endif
