public import CmuxNextSettings

/// Settings > Menus' page route (`cmux.settings.context_menus.*`): ``ContextMenusSettingsPage``,
/// written only by the person's click on Settings. `page` is nil until settings load.
@MainActor
public final class ContextMenusPageProvider: PageProvider {
    public nonisolated static let prefix = ContextMenusSettingsPage.prefix
    private let page: @MainActor () -> ContextMenusSettingsPage?

    public init(page: @escaping @MainActor () -> ContextMenusSettingsPage?) {
        self.page = page
    }

    /// The host lists' `context_menus`; null before settings load.
    public var hostJSON: JSONValue {
        page()?.hostJSON ?? .null
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard context.page == PageDescriptor.settings.id, context.userGesture else {
            throw PageError(code: "cmux.settings.user_only", message: "only you can change your menus")
        }
        guard let page = page() else { throw PageError.unavailable("settings are not loaded yet") }
        guard page.handles(op) else { throw PageError.unknownOp(op) }
        do {
            try await page.run(op, params: params)
        } catch let invalid as ContextMenusSettingsPage.InvalidRequest {
            throw PageError.invalidParams(invalid.message)
        }
        return .object([:])
    }
}
