import CmuxNextPages
import CmuxNextSettings
import CmuxNextUpdater

/// Settings > Server: each server the app heard from, with its status, version line, a "Restart
/// Recommended" row and the socket and Tailscale address it can be reached at
/// (plans/cmux-next/server-updates-DESIGN.md section 10).
///
/// - The page reads `server` in the host lists (`ServerUpdatePresenter.settingsPageJSON`), every text localized.
/// - `restart {kind, host}`: opens the restart confirm, the toast's own; never restarts by itself.
/// - `pair`: opens the Server panel, whose pairing card shows the code.
///
/// Both ops run on the person's click on Settings only.
@MainActor
final class ServerSettingsPageRoute: PageProvider {
    nonisolated static let prefix = "cmux.settings.server."

    private let confirmRestart: @MainActor (ServerKind, ServerHost) -> Void
    private let pair: @MainActor () -> Void

    /// - Parameters:
    ///   - confirmRestart: Opens the restart confirm for one server.
    ///   - pair: Opens the Server panel's pairing card.
    init(confirmRestart: @escaping @MainActor (ServerKind, ServerHost) -> Void, pair: @escaping @MainActor () -> Void) {
        self.confirmRestart = confirmRestart
        self.pair = pair
    }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard context.page == PageDescriptor.settings.id, context.userGesture else {
            throw PageError(code: "cmux.settings.user_only", message: "only you can restart or pair a server")
        }
        switch op {
        case Self.prefix + "restart":
            guard case .string(let raw)? = params["kind"], let kind = ServerKind(rawValue: raw) else {
                throw PageError.invalidParams("kind is required")
            }
            let host: ServerHost
            if case .string(let name)? = params["host"], !name.isEmpty { host = .remote(name) } else { host = .local }
            confirmRestart(kind, host)
            return .object([:])
        case Self.prefix + "pair":
            pair()
            return .object([:])
        default:
            throw PageError.unknownOp(op)
        }
    }
}
