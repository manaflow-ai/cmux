import CmuxHomeCore
import CmuxNextDesign
import SwiftUI

/// The group info sheet (styled as the Home page's other sheets: the theme's popup surface, a
/// title, the content, a status line, then the buttons). A group shows its name (editable),
/// its members with Remove, Add People…, Hide Alerts and Leave Group…; a DM shows the person and
/// Hide Alerts.
struct HomeGroupInfoView: View {
    @Bindable var model: HomeGroupInfoModel
    let colors: HomeGroupInfoColors

    private static let width: CGFloat = 420

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space3) {
            Text(model.info.isGroup ? HomeConversationStrings.infoGroupTitle : HomeConversationStrings.infoDirectTitle)
                .font(Font(Typography.title))
                .foregroundStyle(colors.primary)
                .accessibilityAddTraits(.isHeader)
            if model.info.isGroup {
                nameRow
            } else {
                Text(model.info.displayTitle)
                    .font(Font(Typography.bodyEmphasized))
                    .foregroundStyle(colors.primary)
            }
            members
            if model.info.isGroup { addPeople }
            if model.info.canMute {
                Toggle(HomeConversationStrings.infoHideAlerts, isOn: Binding(get: { model.info.muted }, set: { model.setMuted($0) }))
                    .toggleStyle(.switch)
                    .font(Font(Typography.body))
                    .foregroundStyle(colors.primary)
                    .tint(colors.accent)
                    .accessibilityIdentifier("cmux.home.groupInfo.hideAlerts")
            }
            if let status = model.status {
                Text(status)
                    .font(Font(Typography.caption))
                    .foregroundStyle(colors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cmux.home.groupInfo.status")
            }
            if model.offersInvite {
                Button(HomeConversationStrings.inviteByEmail) { model.inviteByEmail() }
                    .glassButtonStyle()
                    .accessibilityIdentifier("cmux.home.groupInfo.invite")
            }
            buttons
        }
        .padding(Metrics.space6)
        .frame(width: Self.width, alignment: .leading)
        .background(colors.background)
        .tint(colors.accent)
    }

    private var nameRow: some View {
        HStack(spacing: Metrics.space3) {
            ThemedField(text: $model.nameDraft, placeholder: HomeConversationStrings.infoName,
                        identifier: "cmux.home.groupInfo.name", onSubmit: { model.rename() })
            Button(HomeConversationStrings.infoRename) { model.rename() }
                .glassButtonStyle()
                .disabled(!model.canRename)
                .accessibilityIdentifier("cmux.home.groupInfo.rename")
        }
    }

    private var members: some View {
        let info = model.info
        let busy = model.isRunning
        let current = model
        return VStack(alignment: .leading, spacing: Metrics.space1) {
            Text(HomeConversationStrings.infoMembers)
                .font(Font(Typography.caption))
                .foregroundStyle(colors.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(info.members) { member in
                        let id = member.id
                        let remove: (@MainActor () -> Void)? = info.isGroup && !member.isMe && !busy ? { current.remove(id) } : nil
                        HomeGroupMemberRow(member: member, colors: colors, onRemove: remove)
                    }
                }
            }
            .frame(maxHeight: 200)
            .fixedSize(horizontal: false, vertical: info.members.count <= 6)
        }
    }

    @ViewBuilder
    private var addPeople: some View {
        if model.isAdding {
            let chosen = model.addable.filter { model.isChosen($0.id) }.map(\.id)
            VStack(alignment: .leading, spacing: Metrics.space2) {
                ThemedField(text: $model.search, placeholder: HomeConversationStrings.infoAddSearch, focusOnAppear: true,
                            identifier: "cmux.home.groupInfo.search")
                if model.addable.isEmpty {
                    Text(HomeConversationStrings.infoNoOneToAdd)
                        .font(Font(Typography.caption))
                        .foregroundStyle(colors.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(model.shownAddable) { contact in
                                let id = contact.id
                                HomeGroupContactRow(contact: contact, isChosen: chosen.contains(id), colors: colors,
                                                    onToggle: { model.toggle(id) })
                            }
                        }
                    }
                    .frame(maxHeight: 160)
                }
                HStack {
                    Spacer()
                    Button(HomeConversationStrings.cancel) { model.isAdding = false }
                        .glassButtonStyle()
                    Button(HomeConversationStrings.infoAdd) { model.addChosen() }
                        .glassButtonStyle()
                        .disabled(chosen.isEmpty || model.isRunning)
                        .accessibilityIdentifier("cmux.home.groupInfo.addChosen")
                }
            }
        } else {
            Button(HomeConversationStrings.infoAddPeople) { model.isAdding = true }
                .glassButtonStyle()
                .disabled(model.isRunning)
                .accessibilityIdentifier("cmux.home.groupInfo.addPeople")
        }
    }

    private var buttons: some View {
        HStack(spacing: Metrics.space3) {
            if model.info.isGroup {
                Button(HomeConversationStrings.infoLeave, role: .destructive) { model.leave() }
                    .glassButtonStyle()
                    .foregroundStyle(colors.danger)
                    .accessibilityIdentifier("cmux.home.groupInfo.leave")
            }
            Spacer()
            Button(HomeConversationStrings.infoDone) { model.close() }
                .glassButtonStyle()
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("cmux.home.groupInfo.done")
        }
    }
}
