import AppKit
import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextIcons
import SwiftUI

/// Invite People (design chat-multiplayer.md 2, "Invite people"): one chat's invited accounts, an
/// email or @handle field, a Can talk / Can view picker and Invite; each invitee's row has its role
/// and a quiet destructive Remove. A centered dialog over the window, like Share cmux, opened by
/// Invite People… (the tab menu, the palette). It keeps one size while it shows: the list scrolls
/// in a fixed band and the status line keeps its room, so nothing moves when a row comes or goes.
@MainActor
enum AgentShareInviteSheetPresenter {
    static let width: CGFloat = 440

    /// Shows the sheet over the active window and reads who is invited.
    static func present(_ model: AgentShareInviteSheetModel, services: AppServices) {
        let host = services.windows.active?.window.map(WindowOverlayHost.host(for:)) ?? WindowOverlayHost.appHost()
        let card = AgentShareInviteCard(model: model)
        let handle = host.present(card, options: .dialog())
        card.onClose = { [weak handle] in handle?.dismiss() }
        // task-owner: the sheet's first read of the chat's shares; ends with the read
        Task { await model.load() }
    }
}

/// The dialog's card: this Mac's glass under the SwiftUI content, one fixed size.
final class AgentShareInviteCard: NSView {
    var onClose: (() -> Void)?
    let surface = OverlaySurfaceView(interactive: true)

    init(model: AgentShareInviteSheetModel) {
        super.init(frame: .zero)
        let hosting = NSHostingView(rootView: AgentShareInviteSheet(model: model, close: { [weak self] in self?.onClose?() }))
        // The card's size is fixed at its first fit, so the overlay never re-centers it.
        hosting.sizingOptions = []
        let size = hosting.fittingSize
        surface.frame = NSRect(origin: .zero, size: size)
        surface.autoresizingMask = [.width, .height]
        hosting.frame = surface.frame
        hosting.autoresizingMask = [.width, .height]
        addSubview(surface)
        addSubview(hosting)
        setFrameSize(size)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilitySubrole(.dialog)
        setAccessibilityLabel(AgentShareSheetStrings.title(model.chat))
        setAccessibilityModal(true)
        identifier = NSUserInterfaceItemIdentifier("cmux.agentShare.invites")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") } // crash-allow: never decoded from a nib

    override func cancelOperation(_ sender: Any?) { onClose?() }
}

/// The sheet's content.
struct AgentShareInviteSheet: View {
    @Bindable var model: AgentShareInviteSheetModel
    let close: () -> Void

    /// The list's band: four rows, then it scrolls.
    static let listHeight: CGFloat = 4 * 40

    var body: some View {
        let remove: (String) -> Void = { account in
            // task-owner: one Remove; the model ignores a second press for the same account meanwhile
            Task { await model.remove(account) }
        }
        let removing = model.removing
        VStack(alignment: .leading, spacing: Metrics.space3) {
            HStack(alignment: .top) {
                Text(AgentShareSheetStrings.title(model.chat))
                    .font(Font(Typography.title))
                    .lineLimit(2)
                Spacer(minLength: Metrics.space2)
                Button(action: close) {
                    Image(nsImage: NSImage.icon(.actionClose, size: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(AgentShareSheetStrings.close))
                .accessibilityIdentifier("cmux.agentShare.invites.close")
            }
            Text(AgentShareSheetStrings.body)
                .font(Font(Typography.body))
                .foregroundStyle(Color(nsColor: Palette.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Metrics.space2) {
                ThemedField(text: $model.account, placeholder: AgentShareSheetStrings.accountPlaceholder, focusOnAppear: true,
                            identifier: "cmux.agentShare.invites.account",
                            onSubmit: { Task { await model.invite() } }, onCancel: close)
                ThemedPicker(selection: $model.role, choices: ["talk", "view"].map {
                    ThemedPicker.Choice(id: $0, title: AgentShareSheetStrings.role($0))
                }, identifier: "cmux.agentShare.invites.role")
                .fixedSize()
                CmuxDialogActionButton(AgentShareSheetStrings.invite, hint: .return) {
                    // task-owner: one Invite; the model refuses another while it runs
                    Task { await model.invite() }
                }
                .disabled(!model.canInvite)
                .accessibilityIdentifier("cmux.agentShare.invites.invite")
            }
            Text(model.status ?? AgentShareSheetStrings.roleDetail(model.role))
                .font(Font(Typography.caption))
                .foregroundStyle(Color(nsColor: model.status == nil ? Palette.textSecondary : Palette.danger))
                .lineLimit(2, reservesSpace: true)
                .accessibilityIdentifier("cmux.agentShare.invites.status")
            AgentShareInviteList(rows: model.rows, removing: removing, remove: remove)
                .frame(height: Self.listHeight)
            Text(AgentShareSheetStrings.removeNote)
                .font(Font(Typography.caption))
                .foregroundStyle(Color(nsColor: Palette.textTertiary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Metrics.space5)
        .frame(width: AgentShareInviteSheetPresenter.width, alignment: .leading)
    }
}

/// The invitees. Values only below the `ForEach` (no model reference, cmux#2586): each row gets its
/// account and a closure.
struct AgentShareInviteList: View {
    let rows: [AgentShareInviteSheetModel.Row]
    let removing: Set<String>
    let remove: (String) -> Void

    var body: some View {
        if rows.isEmpty {
            Text(AgentShareSheetStrings.empty)
                .font(Font(Typography.body))
                .foregroundStyle(Color(nsColor: Palette.textTertiary))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        AgentShareInviteRow(row: row, isRemoving: removing.contains(row.account)) { remove(row.account) }
                    }
                }
            }
        }
    }
}

/// One invited account: its address, its role (and whether it is in the chat now), and Remove.
struct AgentShareInviteRow: View {
    let row: AgentShareInviteSheetModel.Row
    let isRemoving: Bool
    let remove: () -> Void

    var body: some View {
        HStack(spacing: Metrics.space2) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.account)
                    .font(Font(Typography.body))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(AgentShareSheetStrings.rowDetail(role: row.role, joined: row.joined))
                    .font(Font(Typography.caption))
                    .foregroundStyle(Color(nsColor: Palette.textSecondary))
            }
            Spacer(minLength: Metrics.space2)
            // Quiet destructive text, never a filled red button (design chat-multiplayer.md 2).
            Button(AgentShareSheetStrings.remove, role: .destructive, action: remove)
                .buttonStyle(.plain)
                .font(Font(Typography.body))
                .foregroundStyle(Color(nsColor: Palette.danger))
                .disabled(isRemoving)
                .accessibilityIdentifier("cmux.agentShare.invites.remove")
        }
        .frame(height: 40)
    }
}
