public import AppKit
public import SwiftUI
import CmuxNextDesign
import CmuxNextIcons

/// What a joined machine's menu does (its ellipsis button and its right-click).
public nonisolated enum JoinedMachineAction: String, CaseIterable, Sendable {
    /// `machine doctor ID` in the Check Machine checklist.
    case check
    /// A new credential for it (the old one stops working).
    case rotate
    /// Revoke… (asks first): it leaves the team's machines.
    case revoke

    /// Whether the action can run on a machine in `state` (a revoked machine can only be checked).
    public func isAvailable(for state: JoinedMachine.State) -> Bool {
        self == .check || state != .revoked
    }
}

/// A joined machine's row in the Machines section: its name with the last Check's mark, its state
/// and who made its line, and a "…" button that shows on hover. The hover fill covers the button
/// alone, never the row; the button stays shown and lit while its menu is open. The menu opens on
/// the click (an `NSMenu`, no fade-in).
struct JoinedMachineRowView: View {
    let row: MachineSectionRow
    let machine: JoinedMachine
    let busy: Bool
    let failed: JoinedMachineChange?
    /// Whether this row's menu is open (its button stays shown and lit).
    let menuOpen: Bool
    /// Marks this row's menu open (true) or closed (false) where the section keeps it.
    let menuShown: @MainActor (_ id: String, _ open: Bool) -> Void
    /// New Workspace on a row the app also connects to (`workspace.newOnMachine`).
    let newWorkspace: @MainActor (String) -> Void
    let perform: @MainActor (JoinedMachineAction, JoinedMachine) -> Void

    @State private var rowHovered = false
    @State private var buttonHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: Metrics.panelInset) {
            Icon(.machineRemote, size: Metrics.iconSize)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Metrics.space2) {
                    Text(verbatim: row.name).font(Font(Typography.body)).lineLimit(1)
                    MachineHealthDot(health: row.health)
                }
                Text(verbatim: JoinedMachineStrings.caption(machine, failed: failed))
                    .font(Font(Typography.caption))
                    .foregroundStyle(failed == nil ? Color.secondary : Color(nsColor: Palette.danger))
                    .lineLimit(1)
            }
            .themedHelp(row.healthHelp ?? "")
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: [machine.name, JoinedMachineStrings.caption(machine, failed: failed), row.healthHelp ?? ""]
                .filter { !$0.isEmpty }.joined(separator: ", ")))
            Spacer(minLength: Metrics.panelInset)
            if busy {
                ThemedSpinner(size: 16)
            } else {
                menuButton
                    .opacity(rowHovered || menuOpen ? 1 : 0)
            }
            // Workspaces need a link to the machine; one reached through the mesh alone has none.
            if row.isLinked {
                Button { newWorkspace(row.id) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .disabled(!row.isConnected)
                    .accessibilityLabel(Text(AddMachineStrings.newWorkspace))
            } else {
                Button {} label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .disabled(true)
                    .themedHelp(JoinedMachineStrings.noWorkspace)
                    .accessibilityLabel(Text(AddMachineStrings.newWorkspace))
            }
        }
        .padding(.vertical, 2).padding(.horizontal, Metrics.panelInset)
        .contentShape(Rectangle())
        .onHover { rowHovered = $0 }
        .contextMenu {
            ForEach(JoinedMachineAction.allCases, id: \.self) { action in
                Button(JoinedMachineStrings.title(action)) { perform(action, machine) }
                    .disabled(busy || !action.isAvailable(for: machine.state))
            }
        }
    }

    private var menuButton: some View {
        Button {
            showMenu()
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: JoinedMachineMetrics.buttonSize, height: JoinedMachineMetrics.buttonSize)
                .background(
                    RoundedRectangle(cornerRadius: JoinedMachineMetrics.buttonRadius)
                        .fill(Color(nsColor: Palette.hoverFill))
                        .opacity(buttonHovered || menuOpen ? 1 : 0))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(menuOpen ? .primary : .secondary)
        .onHover { buttonHovered = $0 }
        .accessibilityLabel(Text(JoinedMachineStrings.more(machine.name)))
        .accessibilityIdentifier("cmux.machines.joined.more.\(machine.id)")
    }

    /// Opens the menu under the pointer, lit until it closes. `popUp` returns when the menu
    /// closes; the state change lands first, so the lit button is drawn under the open menu.
    private func showMenu() {
        let id = machine.id, menuShown = menuShown
        menuShown(id, true)
        let menu = JoinedMachineMenu.make(machine, busy: busy, perform: perform)
        let point = NSEvent.mouseLocation
        // task-owner: one menu per click; ends when the menu closes.
        Task { @MainActor in
            menu.popUp(positioning: nil, at: point, in: nil)
            menuShown(id, false)
        }
    }
}

/// The joined machine's menu as an `NSMenu` (the ellipsis button's; opens with no fade-in).
@MainActor
enum JoinedMachineMenu {
    static func make(_ machine: JoinedMachine, busy: Bool, perform: @escaping @MainActor (JoinedMachineAction, JoinedMachine) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for action in JoinedMachineAction.allCases {
            let target = JoinedMachineMenuTarget { perform(action, machine) }
            let item = NSMenuItem(title: JoinedMachineStrings.title(action), action: #selector(JoinedMachineMenuTarget.run), keyEquivalent: "")
            item.target = target
            item.representedObject = target
            item.isEnabled = !busy && action.isAvailable(for: machine.state)
            item.setAccessibilityIdentifier("cmux.machines.joined.\(action.rawValue)")
            if action == .revoke { menu.addItem(.separator()) }
            menu.addItem(item)
        }
        return menu
    }
}

/// Keeps a menu item's closure alive as its target (the item holds it in `representedObject`).
final class JoinedMachineMenuTarget: NSObject {
    private let body: @MainActor () -> Void

    init(_ body: @escaping @MainActor () -> Void) {
        self.body = body
    }

    @MainActor @objc func run() { body() }
}

nonisolated enum JoinedMachineMetrics {
    static let buttonSize: CGFloat = 20
    static let buttonRadius: CGFloat = 5
}

/// Text of the joined rows (Resources/AddMachine.xcstrings).
public nonisolated enum JoinedMachineStrings {
    private static func s(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "AddMachine", bundle: .module)
    }

    /// How long a revoked machine keeps access at most: the platform's heartbeat interval. Every
    /// heartbeat and relay request checks live revocation, so it is cut off at the next one.
    public static let heartbeatSeconds = 30

    static func title(_ action: JoinedMachineAction) -> String {
        switch action {
        case .check: s("machines.joined.check", "Check")
        case .rotate: s("machines.joined.rotate", "Rotate Credential")
        case .revoke: s("machines.joined.revoke", "Revoke…")
        }
    }

    static func caption(_ machine: JoinedMachine, failed: JoinedMachineChange?) -> String {
        if let failed {
            return failed == .revoke ? s("machines.joined.revokeFailed", "Could not revoke it. Try again.")
                : s("machines.joined.rotateFailed", "Could not rotate its credential. Try again.")
        }
        let state = switch machine.state {
        case .online: s("machines.joined.online", "Online")
        case .offline: s("machines.joined.offline", "Offline")
        case .revoked: s("machines.joined.revoked", "Revoked")
        }
        guard let by = machine.mintedBy else { return state }
        return state + " · " + String(format: s("machines.joined.mintedBy", "added by %@"), by)
    }

    static func more(_ name: String) -> String { String(format: s("machines.joined.more", "More for %@"), name) }
    static var noWorkspace: String { s("machines.joined.noWorkspace", "Reached through the mesh; workspaces need a link") }

    public static func revokeTitle(_ name: String) -> String { String(format: s("machines.joined.revokeTitle", "Revoke %@?"), name) }
    public static var revokeBody: String {
        String(format: s("machines.joined.revokeBody", "It leaves your team's machines. Its access ends on its next heartbeat, within %lld seconds. To use it again, paste a new line on it."),
               heartbeatSeconds)
    }
    public static var revokeButton: String { s("machines.joined.revokeButton", "Revoke") }
}
