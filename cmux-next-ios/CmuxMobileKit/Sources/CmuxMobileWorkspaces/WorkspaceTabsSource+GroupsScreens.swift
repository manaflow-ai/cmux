#if os(iOS)
import CmuxTabsKit
import CmuxMobileDesign
import CmuxMobileModel
import SwiftUI

/// A tab group's own actions (the Mac's group chip menu: color, icon, collapse, moves, New Tab
/// in Group) and the workspace's screens (switch, new, rename, close), for the pushed Tab Group
/// and Screens pages (verify/parity-mac.md, Tabs and Screens).
extension WorkspaceTabsSource {
    // MARK: Tab group

    /// The group's member tabs in this workspace, in tab order.
    func members(ofGroup id: String) -> [WorkspaceTab] {
        (workspace?.tabs ?? []).filter { $0.group?.id == id }
    }

    /// A tab group action from its page, on the group through one of its members.
    func editGroup(_ edit: TabGroupEdit, group id: String) async {
        guard let member = members(ofGroup: id).first else { return }
        await editGroup(edit, member.id)
    }

    /// Whether Move Tab Group Left / Right can move the group (not past its pane's edge or a pinned tab).
    func canMoveGroup(_ id: String, forward: Bool) -> Bool {
        guard let workspace, let creator, let member = members(ofGroup: id).first else { return false }
        return creator.backend.canMoveTabGroup(of: member, forward: forward, in: workspace)
    }

    /// New Tab in Group: a terminal in the group's pane on the Mac, in the group; the phone opens it.
    func newTabInGroup(_ id: String) async {
        guard let workspace, let creator, let member = members(ofGroup: id).first else { return }
        if let pending = pendingTabTitle { return show("Still opening \(pending). Try again once it's open.") }
        pendingTabTitle = "New Terminal"
        defer { pendingTabTitle = nil }
        do {
            let tab = try await creator.backend.newTabInGroup(of: member, in: workspace)
            if store.workspace(id: workspaceID)?.tabs.contains(where: { $0.id == tab.id }) != true {
                store.appendTab(tab, to: workspaceID)
            }
            activate(tab.id)
            route = nil
            openedTab = tab.id
        } catch {
            show(error, doing: "open a tab in", member.group?.displayName ?? "the group")
        }
    }

    // MARK: Screens

    /// The page menu's Screens row: the workspace's screens on the Mac, pushed.
    func screensItems(_ tab: WorkspaceTab) -> [TabsKitMenuItem] {
        guard canEditTabs, let screens = workspace?.screens, !screens.isEmpty else { return [] }
        let title = screens.count > 1 ? "Screens (\(screens.count))" : "Screens"
        return [TabsKitMenuItem(id: "screens", title: title, systemImage: "rectangle.stack") { [weak self] in self?.route = .screens }]
    }

    /// The tabs the phone lists on `screen`, in its order.
    func tabs(on screen: MacScreen) -> [WorkspaceTab] {
        let tabs = workspace?.tabs ?? []
        return screen.tabIDs.compactMap { id in tabs.first { $0.id == id } }
    }

    /// Select Screen: the screen becomes the workspace's active screen on the Mac (the phone's
    /// new tabs open there); the Mac's list confirms it.
    func selectScreen(_ screen: MacScreen) async {
        guard let workspace, let creator, !screen.isActive else { return }
        do {
            try await creator.backend.selectScreen(screen, in: workspace)
            CmuxMobileTheme.standard.haptics.selection()
        } catch {
            show(error, doing: "switch to", screenTitle(screen))
        }
    }

    /// New Screen: a screen with a new terminal on the Mac; the phone opens its tab.
    func newScreen() async {
        guard let workspace, let creator else { return }
        if let pending = pendingTabTitle { return show("Still opening \(pending). Try again once it's open.") }
        pendingTabTitle = "New Screen"
        defer { pendingTabTitle = nil }
        do {
            let tab = try await creator.backend.newScreen(in: workspace)
            if store.workspace(id: workspaceID)?.tabs.contains(where: { $0.id == tab.id }) != true {
                store.appendTab(tab, to: workspaceID)
            }
            activate(tab.id)
            route = nil
            openedTab = tab.id
            CmuxMobileTheme.standard.haptics.success()
        } catch {
            show(error, doing: "open", "a new screen")
        }
    }

    /// Rename Screen…: the Mac's name changes once it lists it (an empty name changes nothing).
    func renameScreen(_ screen: MacScreen, to name: String) async {
        renamingScreen = nil
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let workspace, let creator, !name.isEmpty, name != screen.name else { return }
        do {
            try await creator.backend.renameScreen(screen, in: workspace, to: name)
        } catch {
            show(error, doing: "rename", screenTitle(screen))
        }
    }

    /// Close Screen: asks first when a tab on it runs a program (as closing its tabs would),
    /// then closes it on the Mac with its tabs.
    func closeScreen(_ screen: MacScreen) async {
        guard let workspace, let creator, workspace.screens.count > 1 else { return }
        let tabs = tabs(on: screen)
        guard await confirmClose(tabs, in: workspace) else { return }
        do {
            try await creator.backend.closeScreen(screen, in: workspace)
            dropClosedTabs(tabs.map(\.id))
        } catch {
            show(error, doing: "close", screenTitle(screen))
        }
    }

    /// The screen's title as the Mac's bar shows it ("Screen 2", or its name).
    func screenTitle(_ screen: MacScreen) -> String {
        let index = workspace?.screens.firstIndex { $0.id == screen.id } ?? 0
        return screen.title(at: index)
    }
}

/// A screen's title on its tab's card ("Screen 2"), sized in page points like the group chip.
struct ScreenChip: View {
    let title: String

    var body: some View {
        Label(title, systemImage: "rectangle.stack")
            .font(.system(size: 22, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(.black.opacity(0.55), in: .capsule)
            .accessibilityLabel("On \(title)")
    }
}

/// A tab group's icon: an SF Symbol the phone draws, else the emoji as text.
struct TabGroupIcon: View {
    let icon: String

    var body: some View {
        if UIImage(systemName: icon) != nil {
            Image(systemName: icon)
        } else if icon.hasPrefix("image:") || icon.hasPrefix("svg:") {
            // A picture the Mac stores (its icon picker's images): the phone has no copy of it.
            Image(systemName: "photo")
        } else {
            Text(icon)
        }
    }
}

/// A page's toast (the workspace's own toast is under the pushed page): the same short line.
struct PageToast: View {
    let source: WorkspaceTabsSource

    var body: some View {
        ZStack {
            if let text = source.toastText {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                    Text(text).fixedSize(horizontal: false, vertical: true)
                }
                .font(CmuxMobileTheme.standard.type.meta.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
                .accessibilityElement(children: .combine)
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
                .transition(.opacity)
                .id(text)
            }
        }
        .animation(CmuxMobileTheme.standard.motion.snappy.animation, value: source.toastText)
    }
}
#endif
