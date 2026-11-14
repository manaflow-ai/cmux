import AppKit
import CmuxNextActions
import CmuxNextCloud
import CmuxNextDaemonService

extension CloudHandlers {
    static func bindDomainActions(into registry: ActionRegistry, context: AppActionContext, reason: @escaping @MainActor () -> String?) {
        let cloud = context.services.cloud, rules = CloudHandlerRules()
        bind("cloudDomainList", registry, reason: reason) { invocation in
            answer("list Cloud domains", invocation, context) {
                let domains = try await (cloud.previewAPI ?? cloud.api).listDomains()
                let items: [[String: Any]] = domains.map { domain in
                    ["hostname": domain.hostname as Any, "id": domain.id as Any,
                     "verificationState": domain.verificationState as Any, "certificateState": domain.certificateState as Any]
                }
                return cloudAnswer(CloudStrings.domainsTitle, rules.answer(["kind": "domains", "items": items.map(\.compacted)]))
            }
        }
        bind("cloudPublicationList", registry, reason: reason) { invocation in
            answer("list Cloud publications", invocation, context) {
                let publications = try await (cloud.previewAPI ?? cloud.api).listPublications()
                let items: [[String: Any]] = publications.map { publication in
                    ["hostname": publication.hostname as Any, "id": publication.id as Any, "state": publication.state as Any,
                     "accessMode": publication.accessMode as Any]
                }
                return cloudAnswer(CloudStrings.publicationsTitle, rules.answer(["kind": "publications", "items": items.map(\.compacted)]))
            }
        }
        bindAPIActions(into: registry, context: context, reason: reason)
    }

    /// A machine port as an API behind a key (#25594). The key is answered once: a person sees
    /// it in the copyable sheet, a CLI or agent run gets it as `key`; the server keeps its hash.
    static func bindAPIActions(into registry: ActionRegistry, context: AppActionContext, reason: @escaping @MainActor () -> String?) {
        let cloud = context.services.cloud, rules = CloudHandlerRules()
        bind("cloudProvisionAPI", registry, reason: reason) { invocation in
            let session = try machine(invocation, context)
            let asked = try rules.arg("provisionAPI", invocation) as? [String: Any] ?? [:]
            let port = asked["port"] as? Int ?? 0, name = asked["name"] as? String
            answer("provision Cloud API", invocation, context) {
                let api = try await (cloud.previewAPI ?? cloud.api).provisionAPI(machineID: session.machineID, port: port, keyName: name)
                return CloudAnswer(title: CloudStrings.apiTitle, text: CloudStrings.provisionedAPI(url: api.url, key: api.token, cookie: api.cookie),
                                   fields: machineFields(session.machineID, api.actionFields.mapValues(ActionResultValue.string)))
            }
        }
        bind("cloudAPIKeyList", registry, reason: reason) { invocation in
            let publication = try rules.id(invocation, missing: "publicationRequired")
            answer("list Cloud API keys", invocation, context) {
                let keys = try await (cloud.previewAPI ?? cloud.api).listPublicationAPIKeys(publication)
                let items: [[String: Any]] = keys.map { key in ["id": key.id, "name": key.name as Any, "hint": key.hint as Any].compacted }
                return cloudAnswer(CloudStrings.apiKeysTitle, rules.answer(["kind": "apiKeys", "items": items]))
            }
        }
        bind("cloudAPIKeyRevoke", registry, reason: reason) { invocation in
            let publication = try rules.id(invocation, missing: "publicationRequired")
            let keyID = try rules.text("key", invocation)
            answer("revoke Cloud API key", invocation, context) {
                let key = try await (cloud.previewAPI ?? cloud.api).revokePublicationAPIKey(publication, keyID: keyID)
                return CloudAnswer(title: CloudStrings.apiKeysTitle, text: CloudStrings.apiKeyRevoked(key.id),
                                   fields: ["api_key_id": .string(key.id), "revoked_at": .string(key.revokedAt ?? "")])
            }
        }
    }
}
