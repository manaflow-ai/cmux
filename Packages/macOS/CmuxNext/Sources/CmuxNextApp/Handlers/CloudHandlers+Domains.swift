import AppKit
import CmuxNextActions
import CmuxNextCloud

extension CloudHandlers {
    static func bindDomainActions(into registry: ActionRegistry, context: AppActionContext, reason: @escaping @MainActor () -> String?) {
        let cloud = context.services.cloud
        bind("cloudDomainList", registry, reason: reason) { invocation in
            answer("list Cloud domains", invocation, context) {
                let domains = try await cloud.api.listDomains()
                let lines = domains.map { domain in
                    let name = domain.hostname ?? domain.id ?? "(unnamed)"
                    let verification = domain.verificationState ?? "unknown"
                    let certificate = domain.certificateState ?? "unknown"
                    return "\(name) (verification: \(verification), certificate: \(certificate))"
                }
                return CloudAnswer(title: CloudStrings.domainsTitle, text: lines.isEmpty ? "(none)" : lines.joined(separator: "\n"), fields: ["count": .int(domains.count)])
            }
        }
        bind("cloudPublicationList", registry, reason: reason) { invocation in
            answer("list Cloud publications", invocation, context) {
                let publications = try await cloud.api.listPublications()
                let lines = publications.map { publication in
                    let name = publication.hostname ?? publication.id ?? "(unnamed)"
                    let state = publication.state ?? "unknown"
                    let access = publication.accessMode.map { ", access: \($0)" } ?? ""
                    return "\(name) (\(state)\(access))"
                }
                return CloudAnswer(title: CloudStrings.publicationsTitle, text: lines.isEmpty ? "(none)" : lines.joined(separator: "\n"), fields: ["count": .int(publications.count)])
            }
        }
        bindAPIActions(into: registry, context: context, reason: reason)
    }

    /// A machine port as an API behind a key (#25594). The key is answered once: a person sees
    /// it in the copyable sheet, a CLI or agent run gets it as `key`; the server keeps its hash.
    static func bindAPIActions(into registry: ActionRegistry, context: AppActionContext, reason: @escaping @MainActor () -> String?) {
        let cloud = context.services.cloud
        bind("cloudProvisionAPI", registry, reason: reason) { invocation in
            let session = try machine(invocation, context)
            guard let port = invocation["port"]?.intValue, (1...65535).contains(port) else { throw ActionFailure(message: CloudStrings.invalidPort) }
            let name = invocation["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            answer("provision Cloud API", invocation, context) {
                let api = try await cloud.api.provisionAPI(machineID: session.machineID, port: port, keyName: name?.isEmpty == false ? name : nil)
                return CloudAnswer(title: CloudStrings.apiTitle, text: CloudStrings.provisionedAPI(url: api.url, key: api.token, cookie: api.cookie),
                                   fields: machineFields(session.machineID, provisionedAPIFields(api)))
            }
        }
        bind("cloudAPIKeyList", registry, reason: reason) { invocation in
            let publication = try idArgument(invocation, CloudStrings.publicationRequired)
            answer("list Cloud API keys", invocation, context) {
                let keys = try await cloud.api.listPublicationAPIKeys(publication)
                let lines = keys.map { key in "\(key.id) \(key.name ?? "") (…\(key.hint ?? ""))" }
                return CloudAnswer(title: CloudStrings.apiKeysTitle, text: lines.isEmpty ? "(none)" : lines.joined(separator: "\n"), fields: ["count": .int(keys.count)])
            }
        }
        bind("cloudAPIKeyRevoke", registry, reason: reason) { invocation in
            let publication = try idArgument(invocation, CloudStrings.publicationRequired)
            guard let keyID = invocation["key"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !keyID.isEmpty else {
                throw ActionFailure(message: CloudStrings.apiKeyRequired)
            }
            answer("revoke Cloud API key", invocation, context) {
                let key = try await cloud.api.revokePublicationAPIKey(publication, keyID: keyID)
                return CloudAnswer(title: CloudStrings.apiKeysTitle, text: CloudStrings.apiKeyRevoked(key.id),
                                   fields: ["api_key_id": .string(key.id), "revoked_at": .string(key.revokedAt ?? "")])
            }
        }
    }

    /// What a CLI or agent run of Provision API answers besides `text`.
    static func provisionedAPIFields(_ api: CloudProvisionedAPI) -> [String: ActionResultValue] {
        var fields: [String: ActionResultValue] = [
            "url": .string(api.url), "api_key_id": .string(api.apiKey.id), "key": .string(api.token), "cookie": .string(api.cookie),
        ]
        if let id = api.publication.id { fields["publication_id"] = .string(id) }
        if let access = api.publication.accessMode { fields["access"] = .string(access) }
        return fields
    }
}
