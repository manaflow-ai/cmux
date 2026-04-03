import Bonsplit
import SwiftUI

private enum NotificationListFilter: String, CaseIterable, Identifiable {
    case inbox
    case bookmarked
    case hidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inbox:
            return String(localized: "notifications.filter.inbox", defaultValue: "Inbox")
        case .bookmarked:
            return String(localized: "notifications.filter.bookmarked", defaultValue: "Bookmarked")
        case .hidden:
            return String(localized: "notifications.filter.hidden", defaultValue: "Hidden")
        }
    }
}

private enum NotificationSnoozeOption: CaseIterable, Identifiable {
    case fifteenMinutes
    case oneHour
    case fourHours

    var id: Self { self }

    var duration: TimeInterval {
        switch self {
        case .fifteenMinutes:
            return 15 * 60
        case .oneHour:
            return 60 * 60
        case .fourHours:
            return 4 * 60 * 60
        }
    }

    var title: String {
        switch self {
        case .fifteenMinutes:
            return String(localized: "notifications.action.snooze15m", defaultValue: "Snooze 15 Minutes")
        case .oneHour:
            return String(localized: "notifications.action.snooze1h", defaultValue: "Snooze 1 Hour")
        case .fourHours:
            return String(localized: "notifications.action.snooze4h", defaultValue: "Snooze 4 Hours")
        }
    }
}

struct NotificationsPage: View {
    @EnvironmentObject var notificationStore: TerminalNotificationStore
    @EnvironmentObject var tabManager: TabManager
    @Binding var selection: SidebarSelection
    @FocusState private var focusedNotificationId: UUID?
    @AppStorage(KeyboardShortcutSettings.Action.jumpToUnread.defaultsKey) private var jumpToUnreadShortcutData = Data()
    @State private var filter: NotificationListFilter = .inbox

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if displayNotifications.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(displayNotifications) { notification in
                            NotificationRow(
                                notification: notification,
                                tabTitle: tabTitle(for: notification.tabId),
                                focusedNotificationId: $focusedNotificationId,
                                selection: $selection
                            )
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: setInitialFocus)
        .onChange(of: selection) { _, _ in
            setInitialFocus()
        }
        .onChange(of: filter) { _, _ in
            setInitialFocus()
        }
        .onChange(of: displayNotifications.first?.id) { _ in
            setInitialFocus()
        }
    }

    private var displayNotifications: [TerminalNotification] {
        switch filter {
        case .inbox:
            return notificationStore.notifications
        case .bookmarked:
            return notificationStore.bookmarkedNotifications()
        case .hidden:
            return notificationStore.archivedNotifications
        }
    }

    private func setInitialFocus() {
        guard selection == .notifications else { return }
        guard let firstId = displayNotifications.first?.id else {
            focusedNotificationId = nil
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            focusedNotificationId = firstId
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(String(localized: "notifications.title", defaultValue: "Notifications"))
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                if notificationStore.hasMutedSources {
                    mutedSourcesMenu
                }

                if !notificationStore.notifications.isEmpty {
                    jumpToUnreadButton
                }

                if hasAnyNotifications {
                    Button(String(localized: "notifications.clearAll", defaultValue: "Clear All")) {
                        notificationStore.clearAll()
                    }
                    .buttonStyle(.bordered)
                }
            }

            Picker(
                String(localized: "notifications.filter.title", defaultValue: "Notification Filter"),
                selection: $filter
            ) {
                ForEach(NotificationListFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var hasAnyNotifications: Bool {
        !notificationStore.notifications.isEmpty || !notificationStore.archivedNotifications.isEmpty
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: emptyStateImageName)
                .font(.system(size: 32))
                .foregroundColor(.secondary)

            Text(emptyStateTitle)
                .font(.headline)

            Text(emptyStateDescription)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var emptyStateImageName: String {
        switch filter {
        case .inbox:
            return "bell.slash"
        case .bookmarked:
            return "bookmark.slash"
        case .hidden:
            return "eye.slash"
        }
    }

    private var emptyStateTitle: String {
        switch filter {
        case .inbox:
            if hasAnyNotifications {
                return String(localized: "notifications.empty.inboxCleared.title", defaultValue: "Inbox is clear")
            }
            return String(localized: "notifications.empty.title", defaultValue: "No notifications yet")
        case .bookmarked:
            return String(localized: "notifications.empty.bookmarked.title", defaultValue: "No bookmarked notifications")
        case .hidden:
            return String(localized: "notifications.empty.hidden.title", defaultValue: "No hidden notifications")
        }
    }

    private var emptyStateDescription: String {
        switch filter {
        case .inbox:
            if hasAnyNotifications {
                return String(localized: "notifications.empty.inboxCleared.description", defaultValue: "Hidden, snoozed, and bookmarked notifications are still available from the filters above.")
            }
            return String(localized: "notifications.empty.description", defaultValue: "Desktop notifications will appear here for quick review.")
        case .bookmarked:
            return String(localized: "notifications.empty.bookmarked.description", defaultValue: "Bookmark important notifications to keep them easy to revisit.")
        case .hidden:
            return String(localized: "notifications.empty.hidden.description", defaultValue: "Hidden, muted, and snoozed notifications will collect here until you restore them.")
        }
    }

    @ViewBuilder
    private var jumpToUnreadButton: some View {
        if let key = jumpToUnreadShortcut.keyEquivalent {
            Button(action: {
                AppDelegate.shared?.jumpToLatestUnread()
            }) {
                HStack(spacing: 6) {
                    Text(String(localized: "notifications.jumpToLatestUnread", defaultValue: "Jump to Latest Unread"))
                    ShortcutAnnotation(text: jumpToUnreadShortcut.displayString)
                }
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(key, modifiers: jumpToUnreadShortcut.eventModifiers)
            .safeHelp(KeyboardShortcutSettings.Action.jumpToUnread.tooltip(String(localized: "notifications.jumpToLatestUnread", defaultValue: "Jump to Latest Unread")))
            .disabled(!hasUnreadNotifications)
        } else {
            Button(action: {
                AppDelegate.shared?.jumpToLatestUnread()
            }) {
                HStack(spacing: 6) {
                    Text(String(localized: "notifications.jumpToLatestUnread", defaultValue: "Jump to Latest Unread"))
                    ShortcutAnnotation(text: jumpToUnreadShortcut.displayString)
                }
            }
            .buttonStyle(.bordered)
            .safeHelp(KeyboardShortcutSettings.Action.jumpToUnread.tooltip(String(localized: "notifications.jumpToLatestUnread", defaultValue: "Jump to Latest Unread")))
            .disabled(!hasUnreadNotifications)
        }
    }

    private var mutedSourcesMenu: some View {
        Menu {
            if !notificationStore.mutedWorkspaceLabelsById.isEmpty {
                Section(String(localized: "notifications.muted.workspaces", defaultValue: "Muted Workspaces")) {
                    ForEach(sortedMutedWorkspaces, id: \.id) { item in
                        Button(item.label) {
                            notificationStore.unmuteWorkspace(tabId: item.id)
                        }
                    }
                }
            }

            if !notificationStore.mutedProcessLabelsById.isEmpty {
                Section(String(localized: "notifications.muted.processes", defaultValue: "Muted Processes")) {
                    ForEach(sortedMutedProcesses, id: \.id) { item in
                        Button(item.label) {
                            notificationStore.unmuteProcess(identifier: item.id)
                        }
                    }
                }
            }
        } label: {
            Label(String(localized: "notifications.muted.title", defaultValue: "Muted"), systemImage: "bell.slash")
        }
        .menuStyle(BorderlessButtonMenuStyle())
        .fixedSize()
    }

    private var sortedMutedWorkspaces: [(id: UUID, label: String)] {
        notificationStore.mutedWorkspaceLabelsById
            .map { (id: $0.key, label: $0.value) }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    private var sortedMutedProcesses: [(id: String, label: String)] {
        notificationStore.mutedProcessLabelsById
            .map { (id: $0.key, label: $0.value) }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    private var jumpToUnreadShortcut: StoredShortcut {
        decodeShortcut(
            from: jumpToUnreadShortcutData,
            fallback: KeyboardShortcutSettings.Action.jumpToUnread.defaultShortcut
        )
    }

    private var hasUnreadNotifications: Bool {
        notificationStore.notifications.contains(where: { !$0.isRead })
    }

    private func decodeShortcut(from data: Data, fallback: StoredShortcut) -> StoredShortcut {
        guard !data.isEmpty,
              let shortcut = try? JSONDecoder().decode(StoredShortcut.self, from: data) else {
            return fallback
        }
        return shortcut
    }

    private func tabTitle(for tabId: UUID) -> String? {
        AppDelegate.shared?.tabTitle(for: tabId) ?? tabManager.tabs.first(where: { $0.id == tabId })?.title
    }
}

struct ShortcutAnnotation: View {
    let text: String
    var accessibilityIdentifier: String? = nil

    @ViewBuilder
    var body: some View {
        if let accessibilityIdentifier {
            badge.accessibilityIdentifier(accessibilityIdentifier)
        } else {
            badge
        }
    }

    private var badge: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
    }
}

private struct NotificationRow: View {
    @EnvironmentObject private var notificationStore: TerminalNotificationStore

    let notification: TerminalNotification
    let tabTitle: String?
    let focusedNotificationId: FocusState<UUID?>.Binding
    @Binding var selection: SidebarSelection

    private var detailText: String {
        let detail = notification.body.isEmpty ? notification.subtitle : notification.body
        return detail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var metadataText: String? {
        var parts: [String] = []
        if let tabTitle, !tabTitle.isEmpty {
            parts.append(tabTitle)
        }
        if let processDisplayName = notification.processDisplayName,
           !processDisplayName.isEmpty,
           processDisplayName != notification.title {
            parts.append(processDisplayName)
        }
        let result = parts.joined(separator: " · ")
        return result.isEmpty ? nil : result
    }

    private var isArchived: Bool {
        notification.isArchived
    }

    private var bookmarkHelpText: String {
        notification.isBookmarked
            ? String(localized: "notifications.action.removeBookmark", defaultValue: "Remove Bookmark")
            : String(localized: "notifications.action.bookmark", defaultValue: "Bookmark")
    }

    private var archiveHelpText: String {
        isArchived
            ? String(localized: "notifications.action.restore", defaultValue: "Restore to Inbox")
            : String(localized: "notifications.action.hide", defaultValue: "Hide from Inbox")
    }

    private var processIdentifier: String? {
        notification.processIdentifier
    }

    private var shouldShowProcessMute: Bool {
        processIdentifier != nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: openNotification) {
                HStack(alignment: .top, spacing: 12) {
                    unreadIndicator

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 8) {
                            Text(notification.title)
                                .font(.headline)
                                .foregroundColor(.primary)
                                .multilineTextAlignment(.leading)

                            if notification.isBookmarked {
                                Image(systemName: "bookmark.fill")
                                    .font(.caption)
                                    .foregroundStyle(.yellow)
                                    .padding(.top, 2)
                            }

                            Spacer(minLength: 8)

                            Text(notification.createdAt.formatted(date: .omitted, time: .shortened))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        if !detailText.isEmpty {
                            Text(detailText)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .lineLimit(3)
                        }

                        if !statusChips.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(statusChips, id: \.title) { chip in
                                    NotificationStatusChip(
                                        title: chip.title,
                                        systemImage: chip.systemImage,
                                        tint: chip.tint
                                    )
                                }
                            }
                        }

                        if let metadataText {
                            Text(metadataText)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(.trailing, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("NotificationRow.\(notification.id.uuidString)")
            .focusable()
            .focused(focusedNotificationId, equals: notification.id)
            .modifier(DefaultActionModifier(isActive: focusedNotificationId.wrappedValue == notification.id))

            VStack(spacing: 10) {
                iconButton(
                    systemImage: notification.isBookmarked ? "bookmark.fill" : "bookmark",
                    helpText: bookmarkHelpText
                ) {
                    performNotificationAction {
                        notificationStore.toggleBookmark(id: notification.id)
                    }
                }
                .foregroundStyle(notification.isBookmarked ? .yellow : .secondary)

                iconButton(
                    systemImage: isArchived ? "arrow.uturn.backward.circle" : "eye.slash",
                    helpText: archiveHelpText
                ) {
                    performNotificationAction {
                        if isArchived {
                            notificationStore.restore(id: notification.id)
                        } else {
                            notificationStore.hide(id: notification.id)
                        }
                    }
                }

                Menu {
                    notificationActionMenu
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(BorderlessButtonMenuStyle())
                .safeHelp(String(localized: "notifications.action.more", defaultValue: "More Actions"))
            }
            .padding(.top, 2)
            .zIndex(1)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .contextMenu {
            notificationActionMenu
        }
    }

    private var unreadIndicator: some View {
        Circle()
            .fill(notification.isRead ? Color.clear : cmuxAccentColor())
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(cmuxAccentColor().opacity(notification.isRead ? 0.2 : 1), lineWidth: 1)
            )
            .padding(.top, 6)
    }

    private func iconButton(
        systemImage: String,
        helpText: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
        }
        .buttonStyle(.plain)
        .safeHelp(helpText)
    }

    @ViewBuilder
    private var notificationActionMenu: some View {
        Button(String(localized: "notifications.action.open", defaultValue: "Open")) {
            openNotification()
        }

        Button(notification.isRead
               ? String(localized: "notifications.action.markUnread", defaultValue: "Mark Unread")
               : String(localized: "notifications.action.markRead", defaultValue: "Mark Read")) {
            performNotificationAction {
                if notification.isRead {
                    notificationStore.markUnread(id: notification.id)
                } else {
                    notificationStore.markRead(id: notification.id)
                }
            }
        }

        Button(notification.isBookmarked
               ? String(localized: "notifications.action.removeBookmark", defaultValue: "Remove Bookmark")
               : String(localized: "notifications.action.bookmark", defaultValue: "Bookmark")) {
            performNotificationAction {
                notificationStore.toggleBookmark(id: notification.id)
            }
        }

        Button(isArchived
               ? String(localized: "notifications.action.restore", defaultValue: "Restore to Inbox")
               : String(localized: "notifications.action.hide", defaultValue: "Hide from Inbox")) {
            performNotificationAction {
                if isArchived {
                    notificationStore.restore(id: notification.id)
                } else {
                    notificationStore.hide(id: notification.id)
                }
            }
        }

        if !isArchived {
            Divider()

            ForEach(NotificationSnoozeOption.allCases) { option in
                Button(option.title) {
                    performNotificationAction {
                        notificationStore.snooze(id: notification.id, for: option.duration)
                    }
                }
            }
        }

        Divider()

        Button(notificationStore.isWorkspaceMuted(notification.tabId)
               ? String(localized: "notifications.action.unmuteWorkspace", defaultValue: "Unmute Workspace")
               : String(localized: "notifications.action.muteWorkspace", defaultValue: "Mute Workspace")) {
            performNotificationAction {
                if notificationStore.isWorkspaceMuted(notification.tabId) {
                    notificationStore.unmuteWorkspace(tabId: notification.tabId)
                } else {
                    notificationStore.muteWorkspace(tabId: notification.tabId, label: tabTitle)
                }
            }
        }

        if shouldShowProcessMute, let processIdentifier {
            Button(notificationStore.isProcessMuted(processIdentifier)
                   ? String(localized: "notifications.action.unmuteProcess", defaultValue: "Unmute Process")
                   : String(localized: "notifications.action.muteProcess", defaultValue: "Mute Process")) {
                performNotificationAction {
                    if notificationStore.isProcessMuted(processIdentifier) {
                        notificationStore.unmuteProcess(identifier: processIdentifier)
                    } else {
                        notificationStore.muteProcess(
                            identifier: processIdentifier,
                            label: notification.processDisplayName
                        )
                    }
                }
            }
        }

        Divider()

        Button(
            String(localized: "notifications.action.delete", defaultValue: "Delete Permanently"),
            role: .destructive
        ) {
            performNotificationAction {
                notificationStore.remove(id: notification.id)
            }
        }
    }

    private func performNotificationAction(_ action: @escaping () -> Void) {
        DispatchQueue.main.async(execute: action)
    }

    private func openNotification() {
        DispatchQueue.main.async {
            _ = AppDelegate.shared?.openNotification(
                tabId: notification.tabId,
                surfaceId: notification.surfaceId,
                notificationId: notification.id
            )
            selection = .tabs
        }
    }

    private var statusChips: [(title: String, systemImage: String, tint: Color)] {
        var chips: [(title: String, systemImage: String, tint: Color)] = []
        if let archivedReason = notification.archivedReason {
            switch archivedReason {
            case .hidden:
                chips.append((
                    title: String(localized: "notifications.status.hidden", defaultValue: "Hidden"),
                    systemImage: "eye.slash",
                    tint: .secondary
                ))
            case .snoozed:
                let dateText = notification.snoozedUntil?.formatted(date: .omitted, time: .shortened)
                    ?? String(localized: "notifications.status.snoozed", defaultValue: "Snoozed")
                chips.append((
                    title: String(
                        format: String(
                            localized: "notifications.status.snoozedUntil",
                            defaultValue: "Snoozed until %@"
                        ),
                        locale: .current,
                        dateText
                    ),
                    systemImage: "clock",
                    tint: .blue
                ))
            case .mutedWorkspace:
                chips.append((
                    title: String(localized: "notifications.status.mutedWorkspace", defaultValue: "Muted Workspace"),
                    systemImage: "bell.slash",
                    tint: .orange
                ))
            case .mutedProcess:
                chips.append((
                    title: String(localized: "notifications.status.mutedProcess", defaultValue: "Muted Process"),
                    systemImage: "bell.slash",
                    tint: .orange
                ))
            }
        }
        return chips
    }
}

private struct NotificationStatusChip: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(tint.opacity(0.12))
            )
    }
}

private struct DefaultActionModifier: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        if isActive {
            content.keyboardShortcut(.defaultAction)
        } else {
            content
        }
    }
}
