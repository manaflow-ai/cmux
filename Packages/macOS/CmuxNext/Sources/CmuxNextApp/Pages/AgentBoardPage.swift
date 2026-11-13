import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextPages
import CmuxNextSettings

extension InternalPageID {
    static let agentBoard = InternalPageID(rawValue: "agent-board")
}

/// The Agent Board page (``AgentBoardPageProvider``) as an internal page tab, one per window, and
/// `agentBoard.show`. The page is always available: while `agents.board.enabled` is off it shows the
/// onboarding that explains the token cost and turns it on.
enum AgentBoardPageTab {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        services.pages.register(WebPageTab(.agentBoard, symbol: "square.grid.3x3.topleft.filled", title: AgentBoardPageProvider.title) {
            [weak services] in
            let provider = AgentBoardPageProvider(
                enabled: { [weak services] in
                    guard let root = services?.settings?.snapshot.root else { return false }
                    // The flat dotted key is as valid in cmux.json as the nested one.
                    let value = root["agents.board.enabled"] ?? root.value(at: AgentGuidanceSettings.boardEnabledPath)
                    return value?.boolValue == true
                },
                write: { [weak services] on in
                    guard let settings = services?.settings else {
                        throw PageError(code: "cmux.agentBoard.unavailable", message: AgentBoardPageProvider.settingsNotLoaded, retryable: true)
                    }
                    try await settings.setSetting(at: AgentGuidanceSettings.boardEnabledPath, to: .bool(on), by: .user)
                },
                openFile: { url in NSWorkspace.shared.openInBackground(url) },
                openLink: { [weak services] url in
                    guard let opener = services?.linkOpener else { return false }
                    return opener.openWeb(url, from: nil, background: false)
                })
            return PageWebView(descriptor: .agentBoard, routes: [PageRoute(prefix: "cmux.agentBoard.", provider: provider)])
        })
        registry.bindEffect("agentBoard.show") { [weak services] invocation in
            if let services { _ = services.pages.show(.agentBoard, in: services.windows.active, focus: invocation.allowsViewChange) }
            return .done
        }
    }
}
