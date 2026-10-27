public import CmuxNextPages
public import CmuxNextSettings
import CmuxNextUpdater
import Foundation

/// Settings > Updates' Web UI card (plans/cmux-next/web-ota.md): its two buttons,
/// `cmux.settings.web_updates.check` and `cmux.settings.web_updates.rollback`, routed here by
/// prefix so the settings provider stays as it is. They take the paths of `updates.web.check` and
/// `updates.web.rollback`. The card reads ``WebUpdates/pageJSON`` from the host lists.
@MainActor
public final class WebUpdatesPageProvider: PageProvider {
    public static let prefix = "cmux.settings.web_updates."
    private let web: WebUpdates

    public init(web: WebUpdates = .shared) {
        self.web = web
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard op == Self.prefix + "check" || op == Self.prefix + "rollback" else { throw PageError.unknownOp(op) }
        guard let updater = web.updater else {
            throw PageError(code: "cmux.settings.web_updates.unavailable", message: "web updates run on NIGHTLY builds only")
        }
        if op == Self.prefix + "check" {
            // A check that downloads outlasts the call: the card follows its phase in the host lists.
            // task-owner: one check; it ends by itself
            Task { await updater.check() }
            return .object([:])
        }
        guard updater.state.active != nil else {
            throw PageError(code: "cmux.settings.web_updates.rollback_refused", message: "the bundled web is already served")
        }
        do {
            try await updater.rollBack()
        } catch {
            throw PageError(code: "cmux.settings.web_updates.failed", message: error.localizedDescription)
        }
        return .object([:])
    }
}

extension WebUpdates {
    /// The Web UI card's state (`web_updates` in `cmux.settings.host.lists`), null on a bundle that
    /// takes no web updates. Live through `cmux.settings.host.changed`: it reads only observable
    /// state. `served` is the update the pages serve now (null: the bundled web), `active` the one
    /// served from the next safe point, `pending` what that safe point swaps in, `refusal` why the
    /// newest pointer was not taken, as a code the page words.
    public var pageJSON: JSONValue {
        guard let updater else { return .null }
        let phase = switch updater.phase {
        case .idle: "idle"
        case .checking: "checking"
        case .downloading: "downloading"
        case .failed: "failed"
        }
        let pending: JSONValue = switch self.pending {
        case .none: .null
        case .some(nil): .string("bundled")
        case .some(.some): .string("update")
        }
        return [
            "channel": .string(updater.channel.rawValue),
            "phase": .string(phase),
            "served": served.map(Self.pageVersion) ?? .null,
            "active": updater.state.active.map(Self.pageVersion) ?? .null,
            "previous": updater.state.previous.map(Self.pageVersion) ?? .null,
            "pending": pending,
            "last_check": updater.lastCheck.map { .number($0.timeIntervalSince1970.rounded()) } ?? .null,
            "refusal": updater.lastRefusal.map { .string(Self.pageCode($0)) } ?? .null,
        ]
    }

    private static func pageVersion(_ pointer: WebUpdatePointer) -> JSONValue {
        ["commit": .string(pointer.commit), "committed_at": JSONValue(pointer.committedAt)]
    }

    /// The card's words for a refusal: an app too old for the update, nothing newer, an update
    /// no trusted key signed, a download that does not match its signature, no connection.
    static func pageCode(_ refusal: WebUpdateRefusal) -> String {
        switch refusal {
        case .abiMismatch: "app_too_old"
        case .notNewer: "not_newer"
        case .malformed, .unsigned, .wrongChannel: "untrusted"
        case .integrity: "damaged"
        case .transfer: "offline"
        }
    }
}
