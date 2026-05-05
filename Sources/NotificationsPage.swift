import Bonsplit
import SwiftUI

struct NotificationsPage: View {
    @EnvironmentObject var notificationStore: TerminalNotificationStore
    @EnvironmentObject var tabManager: TabManager
    @Binding var selection: SidebarSelection
    @FocusState private var focusedNotificationId: UUID?
    @ObservedObject private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if notificationStore.notifications.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(notificationStore.notifications) { notification in
                            VStack(alignment: .leading, spacing: 6) {
                                NotificationRow(
                                    notification: notification,
                                    tabTitle: tabTitle(for: notification.tabId),
                                    onOpen: {
                                        // SwiftUI action closures are not guaranteed to run on the main actor.
                                        // Ensure window focus + tab selection happens on the main thread.
                                        DispatchQueue.main.async {
                                            _ = AppDelegate.shared?.openNotification(
                                                tabId: notification.tabId,
                                                surfaceId: notification.surfaceId,
                                                notificationId: notification.id
                                            )
                                            selection = .tabs
                                        }
                                    },
                                    onClear: {
                                        notificationStore.remove(id: notification.id)
                                    },
                                    focusedNotificationId: $focusedNotificationId
                                )
                                if let action = notification.action {
                                    TerminalNotificationActionButtons(action: action) {
                                        notificationStore.remove(id: notification.id)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.bottom, 8)
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: setInitialFocus)
        .onChange(of: notificationStore.notifications.first?.id) { _ in
            setInitialFocus()
        }
    }

    private func setInitialFocus() {
        // Only set focus when the notifications page is visible
        // to avoid stealing focus from the terminal when notifications arrive
        guard selection == .notifications else { return }
        guard let firstId = notificationStore.notifications.first?.id else {
            focusedNotificationId = nil
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            focusedNotificationId = firstId
        }
    }

    private var header: some View {
        HStack {
            Text(String(localized: "notifications.title", defaultValue: "Notifications"))
                .font(.title2)
                .fontWeight(.semibold)

            Spacer()

            if !notificationStore.notifications.isEmpty {
                jumpToUnreadButton

                Button(String(localized: "notifications.clearAll", defaultValue: "Clear All")) {
                    notificationStore.clearAll()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bell.slash")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text(String(localized: "notifications.empty.title", defaultValue: "No notifications yet"))
                .font(.headline)
            Text(String(localized: "notifications.empty.description", defaultValue: "Desktop notifications will appear here for quick review."))
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var jumpToUnreadShortcut: StoredShortcut {
        let _ = keyboardShortcutSettingsObserver.revision
        return KeyboardShortcutSettings.shortcut(for: .jumpToUnread)
    }

    private func tabTitle(for tabId: UUID) -> String? {
        AppDelegate.shared?.tabTitle(for: tabId) ?? tabManager.tabs.first(where: { $0.id == tabId })?.title
    }

    private var hasUnreadNotifications: Bool {
        notificationStore.notifications.contains(where: { !$0.isRead })
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

struct TerminalNotificationActionButtons: View {
    let action: TerminalNotificationAction
    let onClear: () -> Void
    @State private var reviewAgent: AgentHookIntegration?

    var body: some View {
        switch action {
        case .agentHookSetup(let agentName):
            if let agent = AgentHookIntegrationSettings.agent(named: agentName) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Button(primaryButtonTitle(for: agent)) {
                            reviewAgent = agent
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button(String(localized: "agentHooks.prompt.notNow", defaultValue: "Not Now")) {
                            AgentHookIntegrationSettings.snoozePrompt(agentName: agent.name)
                            onClear()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button(String(localized: "agentHooks.prompt.never", defaultValue: "Never Show Again")) {
                            AgentHookIntegrationSettings.setPromptEnabled(false)
                            onClear()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .sheet(item: $reviewAgent) { agent in
                    AgentHookDiffReviewView(agent: agent) {
                        onClear()
                    }
                }
            }
        }
    }

    private func primaryButtonTitle(for agent: AgentHookIntegration) -> String {
        return String(localized: "agentHooks.prompt.review", defaultValue: "Review changes")
    }
}

struct AgentHookDiffReviewView: View {
    let agent: AgentHookIntegration
    let onInstalled: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true
    @State private var isInstalling = false
    @State private var diffSucceeded = false
    @State private var diffText = ""
    @State private var message: String?
    @State private var status: AgentHookIntegrationStatus = .unknown

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            Text(String(localized: "agentHooks.diff.subtitle", defaultValue: "Review the config changes before installing hooks."))
                .font(.caption)
                .foregroundStyle(.secondary)

            Group {
                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(String(localized: "agentHooks.diff.loading", defaultValue: "Preparing diff..."))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 280, alignment: .center)
                } else {
                    ScrollView {
                        AgentHookRenderedDiffView(diffText: diffText)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                    .frame(minHeight: 280)
                }
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(String(localized: "agentHooks.diff.cancel", defaultValue: "Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isInstalling)

                Button(installButtonTitle) {
                    install()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isLoading || isInstalling || !diffSucceeded)
            }
        }
        .padding(18)
        .frame(width: 720, height: 520)
        .onAppear {
            loadStatus()
            loadDiff()
        }
    }

    private var title: String {
        if status.isUpdateAvailable {
            return String(localized: "agentHooks.diff.updateTitle", defaultValue: "Update \(agent.displayName) hooks")
        }
        return String(localized: "agentHooks.diff.installTitle", defaultValue: "Install \(agent.displayName) hooks")
    }

    private var installButtonTitle: String {
        if isInstalling {
            return String(localized: "agentHooks.prompt.installing", defaultValue: "Installing...")
        }
        if status.isUpdateAvailable {
            return String(localized: "agentHooks.prompt.update", defaultValue: "Update hooks")
        }
        if agent.isClaudeWrapper {
            return String(localized: "agentHooks.prompt.enable", defaultValue: "Enable")
        }
        return String(localized: "agentHooks.prompt.install", defaultValue: "Install hooks")
    }

    private func loadStatus() {
        let agent = agent
        Task.detached(priority: .utility) {
            let nextStatus = AgentHookIntegrationSettings.status(for: agent)
            await MainActor.run {
                status = nextStatus
            }
        }
    }

    private func loadDiff() {
        isLoading = true
        diffSucceeded = false
        message = nil
        AgentHookIntegrationSettings.diffHooks(for: agent) { result in
            isLoading = false
            diffSucceeded = result.succeeded
            diffText = result.diff.isEmpty
                ? String(localized: "agentHooks.diff.noDiff", defaultValue: "No diff available.")
                : result.diff
            message = result.message.isEmpty ? nil : result.message
        }
    }

    private func install() {
        guard !isInstalling else { return }
        isInstalling = true
        message = nil
        AgentHookIntegrationSettings.installHooks(for: agent) { result in
            isInstalling = false
            if result.succeeded {
                onInstalled()
                dismiss()
            } else {
                message = result.message
            }
        }
    }
}

private struct AgentHookRenderedDiffView: View {
    let diffText: String

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                AgentHookRenderedDiffLine(line: line)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private var lines: [String] {
        diffText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}

private struct AgentHookRenderedDiffLine: View {
    let line: String

    var body: some View {
        Text(line.isEmpty ? " " : line)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 1)
            .background(background)
    }

    private var foreground: Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .green }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .red }
        if line.hasPrefix("@@") { return .cyan }
        return .primary
    }

    private var background: Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return Color.green.opacity(0.10) }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return Color.red.opacity(0.10) }
        if line.hasPrefix("@@") { return Color.cyan.opacity(0.08) }
        if line.hasPrefix("---") || line.hasPrefix("+++") { return Color.secondary.opacity(0.08) }
        return Color.clear
    }
}

private struct NotificationRow: View {
    let notification: TerminalNotification
    let tabTitle: String?
    let onOpen: () -> Void
    let onClear: () -> Void
    let focusedNotificationId: FocusState<UUID?>.Binding

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 12) {
                    Circle()
                        .fill(notification.isRead ? Color.clear : cmuxAccentColor())
                        .frame(width: 8, height: 8)
                        .overlay(
                            Circle()
                                .stroke(cmuxAccentColor().opacity(notification.isRead ? 0.2 : 1), lineWidth: 1)
                        )
                        .padding(.top, 6)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(notification.title)
                                .font(.headline)
                                .foregroundColor(.primary)
                            Spacer()
                            Text(notification.createdAt.formatted(date: .omitted, time: .shortened))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        if !notification.body.isEmpty {
                            Text(notification.body)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .lineLimit(3)
                        }

                        if let tabTitle {
                            Text(tabTitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(.trailing, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("NotificationRow.\(notification.id.uuidString)")
            .focusable()
            .focused(focusedNotificationId, equals: notification.id)
            .modifier(DefaultActionModifier(isActive: focusedNotificationId.wrappedValue == notification.id))

            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
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
