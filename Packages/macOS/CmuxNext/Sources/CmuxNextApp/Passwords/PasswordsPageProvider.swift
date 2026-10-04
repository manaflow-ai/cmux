import AppKit
import CmuxNextPages
import CmuxNextSettings
import Foundation

/// Serves the Passwords page's `cmux.passwords.*` ops (webviews/src/pages/passwords/types.ts,
/// plans/cmux-next/passwords.md 1.4) from a ``PasswordStore``. The page is user-only: no
/// control socket method, CLI verb or MCP tool reaches these ops, and agents never see a row.
///
/// Rules here, so no page bug can weaken them:
/// - replies carry metadata only; no op ever returns a password;
/// - every write needs the person's gesture in the page view (`context.userGesture`, the host's
///   record of a real key or mouse event, never the page's word);
/// - every removal and the export pass a native confirmation the page cannot answer;
/// - reveal, copy and export also need device owner authentication at that moment, and the
///   secret goes only to the native sheet, the pasteboard or the chosen file;
/// - a retried write with the same idempotency key (or opid) replays its first answer and asks
///   nothing again.
@MainActor
final class PasswordsPageProvider: PageProvider {
    /// A browser profile the page can show.
    struct Profile: Equatable {
        var id: String
        var name: String
    }

    let store: any PasswordStore
    let profiles: @MainActor () -> [Profile]
    let confirmations: any PageConfirmationPresenter
    let authenticator: any DeviceOwnerAuthenticating
    let secrets: any PasswordSecretSurface
    /// The page view: the sheets attach to its window.
    var anchor: () -> NSView? = { nil }

    init(store: any PasswordStore, profiles: @escaping @MainActor () -> [Profile], confirmations: any PageConfirmationPresenter,
         authenticator: any DeviceOwnerAuthenticating, secrets: any PasswordSecretSurface) {
        self.store = store
        self.profiles = profiles
        self.confirmations = confirmations
        self.authenticator = authenticator
        self.secrets = secrets
    }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        throw PageError.unknownOp(op)
    }
}

/// The `cmux.passwords/1` op names and error codes (webviews/src/pages/passwords/types.ts).
nonisolated enum PasswordOps {
    static let state = "cmux.passwords.state"
    static let list = "cmux.passwords.list"
    static let passkeysList = "cmux.passwords.passkeys.list"
    static let exceptionsList = "cmux.passwords.exceptions.list"
    static let usernameSet = "cmux.passwords.username.set"
    static let remove = "cmux.passwords.remove"
    static let passkeyRemove = "cmux.passwords.passkey.remove"
    static let exceptionRemove = "cmux.passwords.exception.remove"
    static let reveal = "cmux.passwords.reveal"
    static let copy = "cmux.passwords.copy"
    static let export = "cmux.passwords.export"
    static let changed = "cmux.passwords.changed"

    static let unavailableCode = "cmux.passwords.unavailable"
    static let userOnlyCode = "cmux.passwords.user_only"
    static let notFoundCode = "cmux.passwords.not_found"
    static let failedCode = "cmux.passwords.failed"
    static let authFailedCode = "cmux.passwords.auth_failed"
}
