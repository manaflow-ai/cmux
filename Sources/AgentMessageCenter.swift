import CmuxAgentJournal
import CmuxSettings
import Foundation

/// Owns the app's agent message store and publishes its receipts on the
/// event bus (`cmux events --category agent`).
///
/// It is also the one place the off switches are applied: the app-wide
/// `agentMessages.enabled` setting (read by the store on every send and
/// delivery) and per-surface or per-workspace opt-outs set through
/// ``setReceivingEnabled(_:scope:id:)``, which the socket, CLI and command
/// palette all call.
enum AgentMessageCenter {
    static let store: AgentMessageStore = {
        let store = AgentMessageStore(
            fileURL: defaultFileURL(),
            isEnabled: { AgentMessageCenter.isEnabled() },
            onChange: { change in
                let message = change.message
                CmuxEventBus.shared.publish(
                    name: "agent.message.\(change.state.rawValue)",
                    category: "agent",
                    source: "agent.message",
                    workspaceId: message.recipientWorkspaceId,
                    surfaceId: message.recipientSurfaceId,
                    payload: [
                        "id": message.id,
                        "thread_id": message.threadId,
                        "sender_name": message.senderName,
                        "sender_surface_id": message.senderSurfaceId ?? NSNull(),
                        "state": change.state.rawValue,
                        "delivered_via": message.deliveredVia ?? NSNull(),
                        "failure_reason": message.failureReason ?? NSNull(),
                        "body_length": message.body.count,
                    ]
                )
            }
        )
        // Messages queued before a restart with the switch already off fail
        // now rather than waiting for their recipient to check in.
        store.failBlockedQueued()
        settingsObserver.start(store: store)
        return store
    }()

    private static let settingsObserver = AgentMessageEnabledObserver()

    /// Opens the store (journal replay, the launch sweep, maybe a compaction)
    /// on a background queue at launch, so the first command palette open or
    /// inbox read on main finds it ready. `static let` initialization runs
    /// once; a main-thread caller that races it waits for the same load.
    static func warmStoreOffMain() {
        DispatchQueue.global(qos: .utility).async {
            _ = store
        }
    }

    /// The app-wide switch, `agentMessages.enabled` in cmux.json and
    /// Settings > Automation > Agent Messages.
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        AgentMessagesCatalogSection().enabled.value(in: defaults)
    }

    /// Turns messages for one surface or workspace off or on. Turning them
    /// off fails what was queued for it. The single entry point for the
    /// socket method, the CLI and the command palette. Pass
    /// ``openRecipientsIfAtCapacity()`` so a full store drops an opt-out for
    /// something already closed rather than one still open.
    @discardableResult
    static func setReceivingEnabled(
        _ enabled: Bool,
        scope: AgentMessageRecipientScope,
        id: UUID,
        openRecipients: AgentMessageOpenRecipients? = nil
    ) throws -> [AgentMessage] {
        try store.setReceivingEnabled(enabled, scope: scope, id: id.uuidString, openRecipients: openRecipients)
    }

    /// Every open surface and workspace, gathered only when the opt-out store
    /// is full; `nil` otherwise, which is almost always.
    @MainActor
    static func openRecipientsIfAtCapacity() -> AgentMessageOpenRecipients? {
        guard store.isAtOptOutCapacity, let app = AppDelegate.shared else { return nil }
        let workspaces = app.listMainWindowSummaries()
            .compactMap { app.tabManagerFor(windowId: $0.windowId) }
            .flatMap(\.tabs)
        return AgentMessageOpenRecipients(
            surfaceIds: Set(workspaces.flatMap { $0.panels.keys.map(\.uuidString) }),
            workspaceIds: Set(workspaces.map(\.id.uuidString))
        )
    }

    /// True when the surface or workspace turned messages off.
    static func isReceivingDisabled(scope: AgentMessageRecipientScope, id: UUID) -> Bool {
        store.isReceivingDisabled(scope: scope, id: id.uuidString)
    }

    /// `CMUX_AGENT_MESSAGES_PATH`, else a per-install file next to the agent
    /// journal. In-memory under automated tests.
    static func defaultFileURL(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        isRunningUnderAutomatedTests: Bool = SessionRestorePolicy.isRunningUnderAutomatedTests()
    ) -> URL? {
        if let override = ProcessInfo.processInfo.environment["CMUX_AGENT_MESSAGES_PATH"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        if isRunningUnderAutomatedTests {
            return nil
        }
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let bundleID = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBundleID = bundleID?.isEmpty == false ? bundleID! : "com.cmuxterm.app"
        let safeBundleID = resolvedBundleID.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
        return appSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("agent-messages-\(safeBundleID).jsonl", isDirectory: false)
    }

    static func payload(_ message: AgentMessage) -> [String: Any] {
        [
            "id": message.id,
            "thread_id": message.threadId,
            "sender_name": message.senderName,
            "sender_surface_id": message.senderSurfaceId ?? NSNull(),
            "sender_workspace_id": message.senderWorkspaceId ?? NSNull(),
            "recipient_surface_id": message.recipientSurfaceId,
            "recipient_workspace_id": message.recipientWorkspaceId ?? NSNull(),
            "body": message.body,
            "created_at": message.createdAt.timeIntervalSince1970,
            "in_reply_to": message.inReplyTo ?? NSNull(),
            "state": message.state.rawValue,
            "delivered_at": message.deliveredAt?.timeIntervalSince1970 ?? NSNull(),
            "delivered_via": message.deliveredVia ?? NSNull(),
            "read_at": message.readAt?.timeIntervalSince1970 ?? NSNull(),
            "failure_reason": message.failureReason ?? NSNull(),
        ]
    }
}

/// Fails every queued message when `agentMessages.enabled` turns off, from
/// Settings or a cmux.json reload. Defaults change notifications are frequent,
/// so the sweep runs only on the on-to-off transition.
private final class AgentMessageEnabledObserver: @unchecked Sendable {
    // Lock justification: the notification arrives on whichever thread
    // changed defaults; the guarded state is one Bool and a token.
    private let lock = NSLock()
    private var wasEnabled = true
    private var token: (any NSObjectProtocol)?

    func start(store: AgentMessageStore) {
        lock.withLock {
            guard token == nil else { return }
            wasEnabled = AgentMessageCenter.isEnabled()
            token = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil,
                queue: nil
            ) { [weak self, weak store] _ in
                guard let self, let store else { return }
                self.defaultsDidChange(store: store)
            }
        }
    }

    private func defaultsDidChange(store: AgentMessageStore) {
        let enabled = AgentMessageCenter.isEnabled()
        let turnedOff = lock.withLock {
            defer { wasEnabled = enabled }
            return wasEnabled && !enabled
        }
        if turnedOff {
            store.failBlockedQueued()
        }
    }
}
