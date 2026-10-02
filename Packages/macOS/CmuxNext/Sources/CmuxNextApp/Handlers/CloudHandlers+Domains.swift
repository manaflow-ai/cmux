import AppKit
import CmuxNextActions
import CmuxNextCloud

extension CloudHandlers {
    static func bindDomainActions(into registry: ActionRegistry, context: AppActionContext, reason: @escaping @MainActor () -> String?) {
        let cloud = context.services.cloud!
        bind("cloudDomainList", registry, reason: reason) { _ in
            runTracked("list Cloud domains", context) {
                let domains = try await cloud.api.listDomains()
                let lines = domains.map { domain in
                    let name = domain.hostname ?? domain.id ?? "(unnamed)"
                    let verification = domain.verificationState ?? "unknown"
                    let certificate = domain.certificateState ?? "unknown"
                    return "\(name) (verification: \(verification), certificate: \(certificate))"
                }
                CloudPresenter.show("Cloud Domains", lines.isEmpty ? "(none)" : lines.joined(separator: "\n"), copyable: true, in: window(context))
            }
        }
        bind("cloudPublicationList", registry, reason: reason) { _ in
            runTracked("list Cloud publications", context) {
                let publications = try await cloud.api.listPublications()
                let lines = publications.map { publication in
                    let name = publication.hostname ?? publication.id ?? "(unnamed)"
                    let state = publication.state ?? "unknown"
                    let access = publication.accessMode.map { ", access: \($0)" } ?? ""
                    return "\(name) (\(state)\(access))"
                }
                CloudPresenter.show("Cloud Publications", lines.isEmpty ? "(none)" : lines.joined(separator: "\n"), copyable: true, in: window(context))
            }
        }
    }
}
