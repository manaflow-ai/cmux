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
    }
}
