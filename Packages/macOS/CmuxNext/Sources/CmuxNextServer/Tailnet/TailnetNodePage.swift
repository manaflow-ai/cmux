public import CmuxNextPages
public import CmuxNextSettings
import Foundation

/// The Settings page's side of This Mac on Your Tailnet: `tailnet` in the host lists (every text
/// localized here) and the `cmux.settings.tailnet.*` ops. Every op changes who can reach this Mac
/// or mints a credential, so only the person's own click on the bundled Settings page runs one.
enum TailnetNodePage {
    @MainActor static func json(model: TailnetNodeModel, qr: (String) -> String?) -> JSONValue {
        let S = TailnetNodeText()
        var card: [String: JSONValue] = [
            "title": .string(S.title), "status_title": .string(S.statusTitle),
            "busy": .bool(model.busy), "error": model.actionError.map(JSONValue.string) ?? .null,
            "limit_title": .string(S.limitTitle), "limit_help": .string(S.limitHelp), "limited": .bool(model.access.limitedToAccount),
            // The node reads no access choice yet: the switch shows its owner-only default, disabled.
            "limit_editable": false,
            "sign_in_title": .string(S.signIn), "reopen_title": .string(S.reopen), "cancel_title": .string(S.cancel),
            "sign_out_title": .string(S.signOut), "address_title": .string(S.addressTitle), "copy_title": .string(S.copy),
            "pair_title": .string(S.pair), "done_title": .string(S.done),
        ]
        switch model.phase {
        case .unavailable: card["phase"] = "unavailable"; card["status"] = .string(S.unavailable)
        case .signedOut: card["phase"] = "signed_out"; card["status"] = .string(S.signedOut)
        case .starting: card["phase"] = "starting"; card["status"] = .string(S.starting)
        // The sign-in link itself never goes to the page: Reopen asks the host to open it again.
        case .waitingForBrowser: card["phase"] = "waiting"; card["status"] = .string(S.waiting)
        case .needsApproval: card["phase"] = "needs_approval"; card["status"] = .string(S.needsApproval)
        case .failed(let reason): card["phase"] = "failed"; card["status"] = .string(S.failed(reason))
        case .signedIn(let address, let login):
            card["phase"] = "signed_in"
            card["status"] = .string(login.map(S.signedIn(as:)) ?? S.signedInNoLogin)
            card["address"] = .string(address)
        }
        if let code = model.pairCode {
            card["pair"] = ["qr": qr(code.joinCommand).map(JSONValue.string) ?? .null, "command": .string(code.joinCommand), "help": .string(S.pairHelp)]
        }
        return .object(card)
    }
}

/// `cmux.settings.tailnet.*`: sign_in (also Reopen), cancel, sign_out, pair, close_pair, copy_address.
@MainActor
public final class TailnetNodePageRoute: PageProvider {
    /// Namespace handled exclusively by the bundled Settings page.
    public nonisolated static let prefix = "cmux.settings.tailnet."
    private let service: TailnetNodeService
    private let enabled: @MainActor () -> Bool
    private let copy: (String) -> Void

    /// Injects the Labs gate and the app's pasteboard writer.
    public init(service: TailnetNodeService, enabled: @escaping @MainActor () -> Bool, copy: @escaping (String) -> Void) {
        self.service = service
        self.enabled = enabled
        self.copy = copy
    }

    /// Performs a Tailnet operation only for a Settings-page user gesture.
    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard op.hasPrefix(Self.prefix) else { throw PageError.unknownOp(op) }
        guard enabled() else { throw PageError.unavailable("This Mac on Your Tailnet is a Labs preview") }
        guard context.page == PageDescriptor.settings.id, context.userGesture else {
            throw PageError(code: "cmux.settings.user_only", message: "only you can change who reaches this Mac over Tailscale")
        }
        let model = service.model
        switch String(op.dropFirst(Self.prefix.count)) {
        case "sign_in": await model.signIn()
        case "cancel": model.cancelSignIn()
        case "sign_out": await model.signOut()
        case "pair": await model.pair()
        case "close_pair": model.closePair()
        case "copy_address":
            guard case .signedIn(let address, _) = model.phase else { throw PageError.invalidParams("not signed in") }
            copy(address)
        default: throw PageError.unknownOp(op)
        }
        return .object([:])
    }
}
