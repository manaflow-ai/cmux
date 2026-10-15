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

/// What Share… does to one machine port. A port can carry several publications
/// (a CLI publish plus a menu share, or a custom domain beside the generated
/// one), so its status is the widest audience among all of them, and a chosen
/// audience applies to every one: narrowing one link while another stays
/// public would report a private port that anyone can still open.
struct CloudPortSharePlan: Equatable {
    /// The port's publications, widest audience first.
    let publications: [VMPublication]

    init(publications: [VMPublication], machineID: String, port: Int) {
        self.publications = publications
            .filter { $0.vmID == machineID && $0.port == port }
            .enumerated()
            .sorted {
                let left = Self.breadth($0.element.accessMode)
                let right = Self.breadth($1.element.accessMode)
                return left != right ? left > right : $0.offset < $1.offset
            }
            .map(\.element)
    }

    private static func breadth(_ mode: VMPublicationAccessMode) -> Int {
        switch mode {
        case .personal: 1
        case .team: 2
        case .public: 3
        }
    }

    /// The widest audience any publication of the port has; nil when it has none.
    var current: CloudPortSharing? {
        publications.isEmpty ? nil : CloudPortSharing.widest(publications.map { CloudPortSharing(accessMode: $0.accessMode.rawValue) })
    }

    /// The link the flow shows and copies: the widest publication's.
    var primary: VMPublication? { publications.first }

    /// Whether choosing `mode` makes the port public when it is not already.
    func opensToPublic(_ mode: VMPublicationAccessMode) -> Bool {
        mode == .public && current != .public
    }

    /// The publications whose audience must change to reach `mode`, widest first.
    func updates(to mode: VMPublicationAccessMode) -> [VMPublication] {
        publications.filter { $0.accessMode != mode }
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

    /// Ports whose Share flow is open or still writing, keyed `machine:port`.
    /// A second Share while one runs would read the same "no publication yet"
    /// and create a second one.
    private static var inFlight: Set<String> = []

    /// Starts the flow unless one is already running for this port.
    /// - Returns: Whether a flow started.
    @discardableResult
    static func beginFlow(machineID: String, port: Int) -> Bool {
        inFlight.insert("\(machineID):\(port)").inserted
    }

    static func endFlow(machineID: String, port: Int) {
        inFlight.remove("\(machineID):\(port)")
    }

    static func present(machineID: String, machineLabel: String, port: Int) {
        guard let client = VMClient.shared else {
            showError(String(localized: "cloudPort.share.signedOut", defaultValue: "Sign in to cmux Cloud to share a port."))
            return
        }
        guard beginFlow(machineID: machineID, port: port) else { return }
        Task { @MainActor in
            defer { endFlow(machineID: machineID, port: port) }
            let plan: CloudPortSharePlan
            do {
                let publications = try await client.listPublications()
                CloudPortSharingCache.shared.markRead(machineID: machineID)
                CloudPortSharingCache.shared.record(publications)
                plan = CloudPortSharePlan(publications: publications, machineID: machineID, port: port)
            } catch {
                showError(String(describing: error))
                return
            }
            let portLabel = CloudTreePortPresentation.previewTabTitle(port: port, machineLabel: machineLabel)
            guard let audience = chooseAudience(portLabel: portLabel, plan: plan) else { return }
            if plan.opensToPublic(audience.accessMode), !confirmPublic(portLabel: portLabel) {
                return
            }
            do {
                let publication = try await publish(
                    client: client, machineID: machineID, port: port, audience: audience, plan: plan
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
        plan: CloudPortSharePlan
    ) async throws -> VMPublication {
        let isPublic = audience == .everyone
        if let primary = plan.primary {
            // Every publication of the port gets the chosen audience; the widest
            // one's link is the one shown.
            var shown = primary
            for publication in plan.updates(to: audience.accessMode) {
                let updated = try await client.updatePublicationAccess(
                    id: publication.id, accessMode: audience.accessMode, teamID: nil, confirmPublic: isPublic
                )
                if publication.id == primary.id { shown = updated }
            }
            return shown
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

    private static func chooseAudience(portLabel: String, plan: CloudPortSharePlan) -> Audience? {
        let alert = NSAlert()
        alert.messageText = String(
            format: String(localized: "cloudPort.share.title", defaultValue: "Share %@"),
            portLabel
        )
        let current = plan.current
        let existing = plan.primary
        var info = CloudTreePortPresentation.sharingStatus(current ?? CloudPortSharing.unshared)
        for publication in plan.publications { info += "\n" + publication.url }
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
