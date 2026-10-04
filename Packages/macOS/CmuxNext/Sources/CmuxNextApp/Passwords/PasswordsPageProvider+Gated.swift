import AppKit
import CmuxNextPages
import CmuxNextSettings
import Foundation

/// The gated ops: removals behind a native confirmation, and the three ops that release a
/// secret (reveal, copy, export) behind device owner authentication. The secret never enters a
/// reply; the page only learns that the native step finished.
extension PasswordsPageProvider {
    func removePasswords(_ params: JSONValue, _ context: PageCallContext) async throws -> JSONValue {
        let profile = try self.profile(params)
        let ids = params["ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
        guard !ids.isEmpty else { throw PageError.invalidParams("ids is required") }
        return try await once(params, context) {
            let rows = try await self.mapped { try await self.store.passwords(profile: profile.id) }.filter { ids.contains($0.id) }
            guard !rows.isEmpty else { throw PageError(code: PasswordOps.notFoundCode, message: PasswordStrings.notFound) }
            let name = rows.count == 1 ? Self.label(rows[0]) : PasswordStrings.passwordCount(rows.count)
            try await self.confirm(PageConfirmation(kind: .delete, name: name, detail: PasswordStrings.deletePasswordDetail))
            let removed = try await self.mapped { try await self.store.removePasswords(rows.map(\.id), profile: profile.id) }
            return ["removed": .number(Double(removed))]
        }
    }

    func removePasskey(_ params: JSONValue, _ context: PageCallContext) async throws -> JSONValue {
        let profile = try self.profile(params)
        let id = try Self.string(params, "id")
        return try await once(params, context) {
            let rows = try await self.mapped { try await self.store.passkeys(profile: profile.id) }
            guard let row = rows.first(where: { $0.id == id }) else {
                throw PageError(code: PasswordOps.notFoundCode, message: PasswordStrings.notFound)
            }
            let name = row.userName.isEmpty ? row.relyingParty : "\(row.relyingParty) (\(row.userName))"
            try await self.confirm(PageConfirmation(kind: .delete, name: name, detail: String(format: PasswordStrings.deletePasskeyDetail, row.relyingParty)))
            let removed = try await self.mapped { try await self.store.removePasskey(id, profile: profile.id) }
            return ["removed": .bool(removed)]
        }
    }

    func removeException(_ params: JSONValue, _ context: PageCallContext) async throws -> JSONValue {
        let profile = try self.profile(params)
        let id = try Self.string(params, "id")
        return try await once(params, context) {
            let rows = try await self.mapped { try await self.store.exceptions(profile: profile.id) }
            guard let row = rows.first(where: { $0.id == id }) else {
                throw PageError(code: PasswordOps.notFoundCode, message: PasswordStrings.notFound)
            }
            try await self.confirm(PageConfirmation(kind: .delete, name: row.site, detail: PasswordStrings.deleteExceptionDetail))
            let removed = try await self.mapped { try await self.store.removeException(id, profile: profile.id) }
            return ["removed": .bool(removed)]
        }
    }

    /// Reveal or copy one password: device owner authentication now, then the native sheet or
    /// the pasteboard. Never replayed: each release asks again.
    func releaseSecret(_ op: String, _ params: JSONValue) async throws -> JSONValue {
        let profile = try self.profile(params)
        let id = try Self.string(params, "id")
        let rows = try await mapped { try await store.passwords(profile: profile.id) }
        guard let row = rows.first(where: { $0.id == id }) else {
            throw PageError(code: PasswordOps.notFoundCode, message: PasswordStrings.notFound)
        }
        let reveal = op == PasswordOps.reveal
        try await authenticate(String(format: reveal ? PasswordStrings.revealReason : PasswordStrings.copyReason, row.site))
        let secret = try await mapped { try await store.password(id, profile: profile.id) }
        defer { secret.zero() }
        if reveal {
            await secrets.reveal(secret, site: row.site, username: row.username, anchor: anchor())
            return ["shown": true]
        }
        secrets.copy(secret)
        return ["copied": true]
    }

    /// Export (only while `browser.passwords.allowExport` is on): a native warning that the file is plain text, device owner authentication, the
    /// save panel, then the store writes the CSV. A cancel at any step writes nothing.
    func export(_ params: JSONValue, _ context: PageCallContext) async throws -> JSONValue {
        let profile = try self.profile(params)
        guard await store.capabilities().export else {
            throw PageError(code: PasswordOps.unavailableCode, message: PasswordStrings.availableAfterUpdate)
        }
        return try await once(params, context) {
            try await self.confirm(PageConfirmation(kind: .custom, name: String(format: PasswordStrings.exportTitle, profile.name),
                                                    detail: PasswordStrings.exportDetail))
            try await self.authenticate(PasswordStrings.exportReason)
            guard let url = await self.secrets.exportDestination(profileName: profile.name, anchor: self.anchor()) else {
                throw PageError.cancelled
            }
            let count = try await self.mapped { try await self.store.export(profile: profile.id, to: url) }
            return ["exported": .number(Double(count))]
        }
    }

    // MARK: Steps

    private func confirm(_ confirmation: PageConfirmation) async throws {
        guard await confirmations.confirm(confirmation, anchor: anchor()) else { throw PageError.cancelled }
    }

    private func authenticate(_ reason: String) async throws {
        guard await authenticator.authenticate(reason: reason) else {
            throw PageError(code: PasswordOps.authFailedCode, message: PasswordStrings.authFailed)
        }
    }

    static func label(_ row: SavedPassword) -> String {
        row.username.isEmpty ? row.site : "\(row.site) (\(row.username))"
    }
}
