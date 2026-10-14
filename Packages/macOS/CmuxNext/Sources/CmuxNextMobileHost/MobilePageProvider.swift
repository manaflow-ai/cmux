public import CmuxNextPages
public import CmuxNextSettings

/// The Settings page's `cmux.settings.mobile.*` ops (Settings > Mobile), routed here by
/// prefix so the settings provider stays as it is. Only the person's own gesture on
/// the bundled Settings page may remove a phone, never a script, an agent or another page.
@MainActor
public final class MobilePageProvider: PageProvider {
    private let host: IPhoneHostService

    /// - Parameter host: The app's iPhone host.
    public init(host: IPhoneHostService) {
        self.host = host
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard op == "cmux.settings.mobile.remove_phone" else { throw PageError.unknownOp(op) }
        guard let id = params["id"]?.stringValue, !id.isEmpty else { throw PageError.invalidParams("id is required") }
        guard context.page == PageDescriptor.settings.id, context.userGesture else {
            throw PageError(code: "cmux.settings.user_only", message: "only you can remove a phone")
        }
        await host.removePhone(id: id)
        return .object([:])
    }
}
