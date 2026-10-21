public import Foundation

/// `chief.settings.get` / `chief.settings.set` (cmux-tui resource-operations-v2.json): the
/// brain's per-Chief settings (optchat-chief `optchat/settings.json`, which the brain owns), on
/// the same owner-only path as `chief.engine.*`. The brain checks every change: loosening an
/// approval gate during a remote-origin or another participant's turn is refused
/// (`ChiefControlError.refused`, reason `refused`, with the brain's text).
extension ChiefControlClient {
    /// The brain's answer: `{settings}`, passed through unchanged.
    struct SettingsAnswer: Decodable, Sendable {
        var settings: JSONValue
    }

    /// `chief.settings.get`: the brain's settings JSON. `chief` names a Chief that is not the
    /// default (chief-brains-v1); nil: the default Chief.
    public func chiefSettings(chief: String? = nil) async throws(ChiefControlError) -> JSONValue {
        do {
            return try await connection.resourceRequest({ id in
                ResourceRequestEnvelope(id: id, operation: "chief.settings.get", params: Self.naming(chief, [:]))
            }, as: SettingsAnswer.self).settings
        } catch {
            throw ChiefControlError(error)
        }
    }

    /// `chief.settings.set`: sets one setting (`key` as `optchat-chief settings set` takes it,
    /// `value` as text, for example `approvals.autoApproveAll` `true`); the settings after the
    /// write. `chief` as in `chiefSettings(chief:)`.
    public func setChiefSetting(_ key: String, to value: String, chief: String? = nil) async throws(ChiefControlError) -> JSONValue {
        let params = Self.naming(chief, ["key": .string(key), "value": .string(value)])
        let idempotency = "cmux-next-chief-settings-" + UUID().uuidString.lowercased()
        do {
            return try await connection.resourceRequest({ id in
                ResourceRequestEnvelope(id: id, operation: "chief.settings.set", params: params, idempotencyKey: idempotency)
            }, as: ResourceMutationResult<SettingsAnswer>.self).value.settings
        } catch {
            throw ChiefControlError(error)
        }
    }
}
