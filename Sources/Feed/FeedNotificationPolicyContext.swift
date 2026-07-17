import CMUXAgentLaunch
import CmuxSettings
import Foundation

struct FeedNotificationPolicyContext: Sendable {
  let envelope: TerminalNotificationPolicyEnvelope
  let hooks: [CmuxResolvedNotificationHook]
  let globalConfigPath: String?
}

extension FeedNotificationPolicyContext {
  static func make(
    event: WorkstreamEvent,
    title: String,
    body: String
  ) async -> FeedNotificationPolicyContext {
    let snapshot: FeedNotificationPolicySnapshot = await MainActor.run {
      Self.snapshot(event: event, title: title, body: body)
    }
    return FeedNotificationPolicyContext(
      envelope: snapshot.envelope,
      hooks: snapshot.hooks,
      globalConfigPath: snapshot.globalConfigPath
    )
  }

  @MainActor
  private static func snapshot(
    event: WorkstreamEvent,
    title: String,
    body: String
  ) -> FeedNotificationPolicySnapshot {
    let appDelegate = AppDelegate.shared
    let workspaceID = event.workspaceId.flatMap(UUID.init(uuidString:))
    let context = workspaceID.flatMap { appDelegate?.contextContainingTabId($0) }
    let workspace = workspaceID.flatMap { id in
      context?.tabManager.tabs.first(where: { $0.id == id })
    }
    let cwd =
      normalizedCWD(event.cwd)
      ?? workspace?.surfaceTabBarDirectory
      ?? workspace?.currentDirectory
      ?? FileManager.default.homeDirectoryForCurrentUser.path
    var effects = TerminalNotificationPolicyEffects()
    effects.desktop = true
    effects.record = false
    effects.markUnread = false
    effects.reorderWorkspace = false
    effects.sound = false
    effects.command = false
    effects.paneFlash = false

    let workspaceIdentity = workspaceID?.uuidString ?? ""
    let configStore = workspace == nil ? nil : context?.cmuxConfigStore
    let globalConfigPath = configStore?.globalConfigPath
    let hooks: [CmuxResolvedNotificationHook]
    if context?.tabManager.selectedTabId == workspaceID {
      hooks = configStore?.notificationHooks ?? []
    } else if let globalConfigPath {
      let normalizedGlobalPath = URL(fileURLWithPath: globalConfigPath).standardizedFileURL.path
      hooks =
        configStore?.notificationHooks.filter {
          guard let sourcePath = $0.sourcePath else { return false }
          return URL(fileURLWithPath: sourcePath).standardizedFileURL.path == normalizedGlobalPath
        } ?? []
    } else {
      hooks = []
    }
    return FeedNotificationPolicySnapshot(
      envelope: TerminalNotificationPolicyEnvelope(
        notification: TerminalNotificationPolicyPayload(
          workspaceId: workspaceIdentity,
          surfaceId: nil,
          title: title,
          subtitle: "",
          body: body
        ),
        context: TerminalNotificationPolicyContext(
          cwd: cwd,
          configPath: nil,
          hookId: nil,
          appFocused: AppFocusState.isAppFocused(),
          focusedPanel: false
        ),
        effects: effects
      ),
      hooks: hooks,
      globalConfigPath: globalConfigPath
    )
  }

  private static func normalizedCWD(_ cwd: String?) -> String? {
    guard let cwd else { return nil }
    let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
