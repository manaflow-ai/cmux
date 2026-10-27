import CmuxHomeCore
import CmuxNextDesign
import SwiftUI

/// The group info sheet (styled as the Home page's other sheets: the sheet's glass, a
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
            if model.info.canRename {
                nameRow
            } else {
                Text(model.info.displayTitle)
                    .font(Font(Typography.bodyEmphasized))
                    .foregroundStyle(colors.primary)
            }
            members
            if model.info.canAddPeople { addPeople }
            if let replies = model.info.chiefReplies { chiefRepliesRow(replies) }
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
        let members: [HomeGroupMember] = model.info.members
        let fits: Bool = members.count <= 6
        let header: String = model.info.membersHeader
        return VStack(alignment: .leading, spacing: Metrics.space1) {
            Text(header)
                .font(Font(Typography.caption))
                .foregroundStyle(colors.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(members) { member in
                        memberRow(member)
                    }
                }
                .thinScrollers()
            }
            .frame(maxHeight: 200)
            .fixedSize(horizontal: false, vertical: fits)
        }
    }

    /// When the group's Chiefs answer (plans/cmux-next/chief-group-chats-DESIGN.md section 3).
    private func chiefRepliesRow(_ replies: ChiefReplyPolicy) -> some View {
        let current: HomeGroupInfoModel = model
        return VStack(alignment: .leading, spacing: Metrics.space1) {
            Picker(HomeConversationStrings.infoChiefReplies, selection: Binding(get: { replies }, set: { current.setChiefReplies($0) })) {
                ForEach(ChiefReplyPolicy.allCases, id: \.self) { policy in
                    Text(HomeConversationStrings.chiefReplies(policy)).tag(policy)
                }
            }
            .pickerStyle(.menu)
            .font(Font(Typography.body))
            .foregroundStyle(colors.primary)
            .disabled(model.isRunning)
            .accessibilityIdentifier("cmux.home.groupInfo.chiefReplies")
            Text(HomeConversationStrings.chiefRepliesDetail(replies))
                .font(Font(Typography.caption))
                .foregroundStyle(colors.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One member row; Remove only for another member of a group (a person I shared my Chief with)
    /// while no action runs.
    private func memberRow(_ member: HomeGroupMember) -> HomeGroupMemberRow {
        guard model.info.canRename || (model.info.canAddPeople && !member.isAgent), !member.isMe, !model.isRunning else {
            return HomeGroupMemberRow(member: member, colors: colors, onRemove: nil)
        }
        let current: HomeGroupInfoModel = model
        let id: ParticipantID = member.id
        let remove: @MainActor () -> Void = { current.remove(id) }
        return HomeGroupMemberRow(member: member, colors: colors, onRemove: remove)
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
                                contactRow(contact, isChosen: chosen.contains(contact.id))
                            }
                        }
                        .thinScrollers()
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

    /// One contact row of Add People; its toggle chooses or unchooses the contact.
    private func contactRow(_ contact: HomeContact, isChosen: Bool) -> HomeGroupContactRow {
        let current: HomeGroupInfoModel = model
        let id: ParticipantID = contact.id
        let toggle: @MainActor () -> Void = { current.toggle(id) }
        return HomeGroupContactRow(contact: contact, isChosen: isChosen, colors: colors, onToggle: toggle)
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
            CmuxDialogActionButton(HomeConversationStrings.infoDone, hint: .escape) { model.close() }
                .glassButtonStyle()
                .accessibilityIdentifier("cmux.home.groupInfo.done")
        }
    }
}
