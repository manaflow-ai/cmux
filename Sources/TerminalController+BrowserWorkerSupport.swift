import Foundation

extension TerminalController {
    nonisolated func v2BrowserPanelFields(
        _ context: V2BrowserPanelContext,
        adding fields: [String: Any] = [:]
    ) -> [String: Any] {
        var result: [String: Any] = [
            "workspace_id": context.workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: context.workspaceId),
            "surface_id": context.surfaceId.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: context.surfaceId),
        ]
        fields.forEach { result[$0.key] = $0.value }
        return result
    }

    /// Resolves browser UI state on the main actor, then runs callback-waiting work on the socket worker.
    nonisolated func v2BrowserWithPanelContext(
        params: [String: Any],
        allowSoleBrowserFallback: Bool = false,
        _ body: (_ context: V2BrowserPanelContext) -> V2CallResult
    ) -> V2CallResult {
        var resolved: V2BrowserPanelContext?
        var failure = V2CallResult.err(
            code: "internal_error",
            message: String(
                localized: "cli.browser.error.operationFailed",
                defaultValue: "Browser operation failed"
            ),
            data: nil
        )
        v2MainSync {
            guard let tabManager = v2ResolveTabManager(params: params) else {
                failure = .err(
                    code: "unavailable",
                    message: String(
                        localized: "cli.browser.error.tabManagerUnavailable",
                        defaultValue: "Browser controls are unavailable"
                    ),
                    data: nil
                )
                return
            }
            let result = v2ResolveBrowserPanelContext(
                params: params,
                tabManager: tabManager,
                allowSoleBrowserFallback: allowSoleBrowserFallback
            )
            if let error = result.error {
                failure = error
                return
            }
            guard let context = result.context else { return }
            resolved = context
        }
        guard let resolved else { return failure }
        return body(resolved)
    }

    nonisolated func v2AwaitCallback<T>(
        timeout: TimeInterval,
        start: (@escaping (T) -> Void) -> Void
    ) -> T? {
        socketAwaitCallback(timeout: timeout, start: start)
    }
}
