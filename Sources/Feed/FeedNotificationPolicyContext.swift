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
    body: String,
    hookCache: CmuxNotificationHookCache,
    defaultGlobalConfigPath: String = CmuxConfigStore.defaultGlobalConfigPath()
  ) async -> FeedNotificationPolicyContext {
    let snapshot: FeedNotificationPolicySnapshot = await MainActor.run {
      Self.snapshot(
        event: event,
        title: title,
        body: body,
        defaultGlobalConfigPath: defaultGlobalConfigPath
      )
    }
    let hooks: [CmuxResolvedNotificationHook]
    if let globalConfigPath = snapshot.globalConfigPath {
      hooks = await hookCache.hooks(
        startingFrom: snapshot.hookSearchDirectory,
        globalConfigPath: globalConfigPath
      )
    } else {
      hooks = []
    }
    return FeedNotificationPolicyContext(
      envelope: snapshot.envelope,
      hooks: hooks,
      globalConfigPath: snapshot.globalConfigPath
    )
  }

  @MainActor
  private static func snapshot(
    event: WorkstreamEvent,
    title: String,
    body: String,
    defaultGlobalConfigPath: String
  ) -> FeedNotificationPolicySnapshot {
    let appDelegate = AppDelegate.shared
    let workspaceID = event.workspaceId.flatMap(UUID.init(uuidString:))
    let workspaceContext = workspaceID.flatMap { appDelegate?.contextContainingTabId($0) }
    let configContext = workspaceContext
    let workspace = workspaceID.flatMap { id in
      workspaceContext?.tabManager.tabs.first(where: { $0.id == id })
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
    let globalConfigPath = configContext?.cmuxConfigStore?.globalConfigPath
      ?? defaultGlobalConfigPath
    let hookSearchDirectory = workspace?.isRemoteWorkspace == true
      ? nil
      : (normalizedCWD(event.cwd) ?? workspace?.surfaceTabBarDirectory)
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
      globalConfigPath: globalConfigPath,
      hookSearchDirectory: hookSearchDirectory
    )
  }

  private static func normalizedCWD(_ cwd: String?) -> String? {
    guard let cwd else { return nil }
    let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
