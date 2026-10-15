import AppKit
import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation

/// The last publication audience read for each machine port, so a port's menu
/// can say whether it is private, shared or public. Written only from
/// publication reads and from the Share flow's own result.
@MainActor
final class CloudPortSharingCache {
    static let shared = CloudPortSharingCache()

    private var byMachine: [String: [Int: CloudPortSharing]] = [:]
    private var refreshing = false

    /// `nil` until this machine's publications have been read once.
    func sharing(machineID: String, port: Int) -> CloudPortSharing? {
        byMachine[machineID].map { $0[port] ?? CloudPortSharing.unshared }
    }

    func record(_ publications: [VMPublication]) {
        var next: [String: [Int: [CloudPortSharing]]] = [:]
        for publication in publications {
            next[publication.vmID, default: [:]][publication.port, default: []]
                .append(CloudPortSharing(accessMode: publication.accessMode.rawValue))
        }
        // Machines with no publication are known to be private.
        for machine in byMachine.keys where next[machine] == nil { next[machine] = [:] }
        byMachine = next.mapValues { $0.mapValues(CloudPortSharing.widest) }
    }

    func markRead(machineID: String) {
        if byMachine[machineID] == nil { byMachine[machineID] = [:] }
    }

    /// Reads publications in the background; the next menu shows the result.
    func refresh(machineID: String) {
        guard !refreshing, let client = VMClient.shared else { return }
        refreshing = true
        Task { @MainActor [self] in
            defer { self.refreshing = false }
            guard let publications = try? await client.listPublications() else { return }
            self.markRead(machineID: machineID)
            self.record(publications)
        }
    }
}

/// Share… for a machine port: private by default, and public only after a
/// second confirmation that names who will be able to open it. Uses the same
/// publication API as `cmux cloud domains publish` / `access`. Each step is an
/// app-modal alert so the flow reads one answer before taking the next step.
@MainActor
enum CloudPortShareFlow {
    enum Audience: CaseIterable {
        case personal, team, everyone

        var accessMode: VMPublicationAccessMode {
            switch self {
            case .personal: .personal
            case .team: .team
            case .everyone: .public
            }
        }

        init(_ sharing: CloudPortSharing?) {
            switch sharing {
            case .team?: self = .team
            case .public?: self = .everyone
            default: self = .personal
            }
        }

        var title: String {
            switch self {
            case .personal:
                String(localized: "cloudPort.share.audience.personal", defaultValue: "Only you (sign-in required)")
            case .team:
                String(localized: "cloudPort.share.audience.team", defaultValue: "Your team (sign-in required)")
            case .everyone:
                String(localized: "cloudPort.share.audience.public", defaultValue: "Anyone with the link (public)")
            }
        }
    }

    static func present(machineID: String, machineLabel: String, port: Int) {
        guard let client = VMClient.shared else {
            showError(String(localized: "cloudPort.share.signedOut", defaultValue: "Sign in to cmux Cloud to share a port."))
            return
        }
        Task { @MainActor in
            let existing: VMPublication?
            do {
                let publications = try await client.listPublications()
                CloudPortSharingCache.shared.markRead(machineID: machineID)
                CloudPortSharingCache.shared.record(publications)
                existing = publications.first { $0.vmID == machineID && $0.port == port }
            } catch {
                showError(String(describing: error))
                return
            }
            let portLabel = CloudTreePortPresentation.previewTabTitle(port: port, machineLabel: machineLabel)
            guard let audience = chooseAudience(portLabel: portLabel, existing: existing) else { return }
            if audience == .everyone, existing?.accessMode != .public,
               !confirmPublic(portLabel: portLabel) {
                return
            }
            do {
                let publication = try await publish(
                    client: client, machineID: machineID, port: port, audience: audience, existing: existing
                )
                if let publications = try? await client.listPublications() {
                    CloudPortSharingCache.shared.record(publications)
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(publication.url, forType: .string)
                showResult(publication: publication, portLabel: portLabel)
            } catch {
                showError(String(describing: error))
            }
        }
    }

    private static func publish(
        client: VMClient,
        machineID: String,
        port: Int,
        audience: Audience,
        existing: VMPublication?
    ) async throws -> VMPublication {
        let isPublic = audience == .everyone
        if let existing {
            guard existing.accessMode != audience.accessMode else { return existing }
            return try await client.updatePublicationAccess(
                id: existing.id, accessMode: audience.accessMode, teamID: nil, confirmPublic: isPublic
            )
        }
        // Like `cmux cloud domains publish --access public`: reserve the name
        // privately first, then open it, so a failure never leaves it public.
        let created = try await client.createPublication(
            vmID: machineID,
            port: port,
            hostname: nil,
            accessMode: isPublic ? .personal : audience.accessMode,
            teamID: nil
        )
        guard isPublic else { return created }
        return try await client.updatePublicationAccess(id: created.id, accessMode: .public, teamID: nil, confirmPublic: true)
    }

    private static func chooseAudience(portLabel: String, existing: VMPublication?) -> Audience? {
        let alert = NSAlert()
        alert.messageText = String(
            format: String(localized: "cloudPort.share.title", defaultValue: "Share %@"),
            portLabel
        )
        let current = existing.map { CloudPortSharing(accessMode: $0.accessMode.rawValue) }
        var info = CloudTreePortPresentation.sharingStatus(current ?? CloudPortSharing.unshared)
        if let existing { info += "\n" + existing.url }
        info += "\n\n" + String(
            localized: "cloudPort.share.explain",
            defaultValue: "Sharing gives the port an HTTPS address. The private preview keeps working either way."
        )
        alert.informativeText = info
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26), pullsDown: false)
        for audience in Audience.allCases { popup.addItem(withTitle: audience.title) }
        popup.selectItem(at: Audience.allCases.firstIndex(of: Audience(current)) ?? 0)
        alert.accessoryView = popup
        alert.addButton(withTitle: existing == nil
            ? String(localized: "cloudPort.share.confirm", defaultValue: "Share")
            : String(localized: "cloudPort.share.update", defaultValue: "Update Access"))
        alert.addButton(withTitle: String(localized: "cloudPort.share.cancel", defaultValue: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let index = popup.indexOfSelectedItem
        return Audience.allCases.indices.contains(index) ? Audience.allCases[index] : nil
    }

    /// The explicit second step before anything becomes public. It names the
    /// audience (anyone on the internet, no sign-in) and keeps Cancel the default.
    private static func confirmPublic(portLabel: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: String(localized: "cloudPort.share.public.title", defaultValue: "Make %@ public?"),
            portLabel
        )
        alert.informativeText = String(
            localized: "cloudPort.share.public.message",
            defaultValue: "Anyone on the internet who has the link can open this server without signing in. Treat the link like a password, and only do this for a server that is safe to expose."
        )
        let makePublic = alert.addButton(withTitle: String(localized: "cloudPort.share.public.confirm", defaultValue: "Make Public"))
        let cancel = alert.addButton(withTitle: String(localized: "cloudPort.share.cancel", defaultValue: "Cancel"))
        makePublic.hasDestructiveAction = true
        makePublic.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func showResult(publication: VMPublication, portLabel: String) {
        let alert = NSAlert()
        alert.messageText = String(
            format: String(localized: "cloudPort.share.done.title", defaultValue: "%@ is shared"),
            portLabel
        )
        alert.informativeText = CloudTreePortPresentation.sharingStatus(CloudPortSharing(accessMode: publication.accessMode.rawValue))
            + "\n" + publication.url + "\n\n"
            + String(localized: "cloudPort.share.done.copied", defaultValue: "The link is on the clipboard.")
        alert.addButton(withTitle: String(localized: "cloudPort.share.done.ok", defaultValue: "OK"))
        _ = alert.runModal()
    }

    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "cloudPort.share.failed", defaultValue: "Could not share the port")
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "cloudPort.share.done.ok", defaultValue: "OK"))
        _ = alert.runModal()
    }
}
