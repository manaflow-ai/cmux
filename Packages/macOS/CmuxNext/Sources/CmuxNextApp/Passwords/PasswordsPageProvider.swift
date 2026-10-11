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
    private var replies: [(key: String, value: JSONValue)] = []
    private static let replayLimit = 64
    private var revision = 0

    init(store: any PasswordStore, profiles: @escaping @MainActor () -> [Profile], confirmations: any PageConfirmationPresenter,
         authenticator: any DeviceOwnerAuthenticating, secrets: any PasswordSecretSurface) {
        self.store = store
        self.profiles = profiles
        self.confirmations = confirmations
        self.authenticator = authenticator
        self.secrets = secrets
    }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case PasswordOps.state:
            return try await state()
        case PasswordOps.list:
            let profile = try self.profile(params)
            let rows = try await mapped { try await self.store.passwords(profile: profile.id) }
            return ["passwords": .array(rows.map { Self.json($0) })]
        case PasswordOps.passkeysList:
            let profile = try self.profile(params)
            let rows = try await mapped { try await self.store.passkeys(profile: profile.id) }
            return ["passkeys": .array(rows.map { Self.json($0) })]
        case PasswordOps.exceptionsList:
            let profile = try self.profile(params)
            let rows = try await mapped { try await self.store.exceptions(profile: profile.id) }
            return ["exceptions": .array(rows.map { ["id": .string($0.id), "site": .string($0.site)] })]
        case PasswordOps.usernameSet:
            try requireGesture(context)
            let profile = try self.profile(params)
            let id = try Self.string(params, "id")
            guard let username = params["username"]?.stringValue else { throw PageError.invalidParams("username is required") }
            return try await once(params, context) {
                try await self.mapped { try await self.store.setUsername(username, id: id, profile: profile.id) }
                return .object([:])
            }
        case PasswordOps.remove:
            try requireGesture(context)
            return try await removePasswords(params, context)
        case PasswordOps.passkeyRemove:
            try requireGesture(context)
            return try await removePasskey(params, context)
        case PasswordOps.exceptionRemove:
            try requireGesture(context)
            return try await removeException(params, context)
        case PasswordOps.reveal, PasswordOps.copy:
            try requireGesture(context)
            return try await releaseSecret(op, params)
        case PasswordOps.export:
            try requireGesture(context)
            return try await export(params, context)
        default:
            throw PageError.unknownOp(op)
        }
    }

    /// `cmux.passwords.changed {profile, revision}`: one event per change of a profile's store.
    func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == PasswordOps.changed else { throw PageError.unknownOp(stream) }
        let stop = store.observe { [weak self] profile in
            guard let self else { return }
            self.revision += 1
            onEvent(["profile": .string(profile), "revision": .number(Double(self.revision))])
        }
        return PageSubscription { stop() }
    }

    // MARK: Reads

    private func state() async throws -> JSONValue {
        let capabilities = await store.capabilities()
        let list = profiles()
        return [
            "profiles": .array(list.map { ["id": .string($0.id), "name": .string($0.name)] }),
            "profile": .string(list.first?.id ?? "default"),
            "sections": [
                "passwords": .bool(capabilities.passwords), "passkeys": .bool(capabilities.passkeys),
                "exceptions": .bool(capabilities.exceptions), "export": .bool(capabilities.export),
            ],
        ]
    }

    static func json(_ row: SavedPassword) -> JSONValue {
        [
            "id": .string(row.id), "site": .string(row.site), "url": .string(row.url), "username": .string(row.username),
            "created": time(row.created), "last_used": time(row.lastUsed), "times_used": .number(Double(row.timesUsed)),
            "weak": .bool(row.weak), "reused": .bool(row.reused),
        ]
    }

    static func json(_ row: SavedPasskey) -> JSONValue {
        ["id": .string(row.id), "rp_id": .string(row.relyingParty), "user_name": .string(row.userName),
         "user_display_name": .string(row.userDisplayName)]
    }

    private static func time(_ date: Date?) -> JSONValue {
        date.map { .number(($0.timeIntervalSince1970 * 1000).rounded()) } ?? .null
    }

    // MARK: Shared checks

    /// The profile `params` names (`default` when it names none); unknown ids are refused.
    func profile(_ params: JSONValue) throws -> Profile {
        let id = params["profile"]?.stringValue ?? "default"
        guard let profile = profiles().first(where: { $0.id == id }) else { throw PageError.invalidParams("unknown profile \(id)") }
        return profile
    }

    static func string(_ params: JSONValue, _ key: String) throws -> String {
        guard let value = params[key]?.stringValue, !value.isEmpty else { throw PageError.invalidParams("\(key) is required") }
        return value
    }

    /// A write needs a real key or mouse event in the page view: page script alone writes nothing.
    func requireGesture(_ context: PageCallContext) throws {
        guard context.page == PageDescriptor.passwords.id, context.userGesture else {
            throw PageError(code: PasswordOps.userOnlyCode, message: PasswordStrings.userOnly)
        }
    }

    /// Runs a store call and turns its errors into the page codes.
    func mapped<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as PasswordStoreError {
            switch error {
            case .unavailable: throw PageError(code: PasswordOps.unavailableCode, message: PasswordStrings.availableAfterUpdate)
            case .notFound: throw PageError(code: PasswordOps.notFoundCode, message: PasswordStrings.notFound)
            case .failed(let reason): throw PageError(code: PasswordOps.failedCode, message: reason)
            }
        }
    }

    /// Runs one write once per idempotency key (or opid); a retry replays the first answer.
    func once(_ params: JSONValue, _ context: PageCallContext, _ write: () async throws -> JSONValue) async throws -> JSONValue {
        let key = params["idempotency_key"]?.stringValue ?? context.opid
        if let key, let reply = replies.first(where: { $0.key == key }) {
            guard case .object(var members) = reply.value else { return reply.value }
            members["replayed"] = .bool(true)
            return .object(members)
        }
        let value = try await write()
        if let key {
            replies.append((key, value))
            if replies.count > Self.replayLimit { replies.removeFirst() }
        }
        return value
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
