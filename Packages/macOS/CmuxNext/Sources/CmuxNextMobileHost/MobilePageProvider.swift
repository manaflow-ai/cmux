public import CmuxNextPages
public import CmuxNextSettings

/// The Settings page's `cmux.settings.mobile.*` ops (Settings > Mobile), routed here by
/// prefix so the settings provider stays as it is. Only the person's own gesture on
/// the bundled Settings page may remove a phone, answer a phone's pairing request or allow
/// connections again after this Mac was removed, never a script, an agent or another page.
@MainActor
public final class MobilePageProvider: PageProvider {
    private let host: IPhoneHostService

    /// - Parameter host: The app's iPhone host.
    static let ops: Set<String> = ["cmux.settings.mobile.remove_phone", "cmux.settings.mobile.allow_again", "cmux.settings.mobile.answer_pair"]

    public init(host: IPhoneHostService) {
        self.host = host
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard Self.ops.contains(op) else { throw PageError.unknownOp(op) }
        // Each changes which devices may reach this Mac: the person's own gesture only.
        guard context.page == PageDescriptor.settings.id, context.userGesture else {
            throw PageError(code: "cmux.settings.user_only", message: "only you can change which iPhones reach this Mac")
        }
        if op == "cmux.settings.mobile.allow_again" {
            host.allowAgain()
            return .object([:])
        }
        guard let id = params["id"]?.stringValue, !id.isEmpty else { throw PageError.invalidParams("id is required") }
        if op == "cmux.settings.mobile.answer_pair" {
            guard case .bool(let allow)? = params["allow"] else { throw PageError.invalidParams("allow is required") }
            guard host.answerPairRequest(id: id, allow: allow) else { throw PageError.invalidParams("no request from that phone is waiting") }
            return .object([:])
        }
        await host.removePhone(id: id)
        return .object([:])
    }
}
