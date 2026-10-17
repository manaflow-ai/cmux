import AppKit
import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation

/// The Cloud machine port a share control acts on.
struct CloudPortShareContext: Equatable {
    let machineID: String
    let machineLabel: String
    let port: Int

    /// `:3000 · vivid-newt`, the same identity the Ports row and the preview tab use.
    var portLabel: String {
        CloudTreePortPresentation.previewTabTitle(port: port, machineLabel: machineLabel)
    }
}

extension CloudPortShareAudience {
    /// The audience menu row ("Only you", "Team", "Anyone with the link").
    var menuTitle: String {
        switch self {
        case .personal:
            String(localized: "cloudPort.share.audience.personal", defaultValue: "Only you (sign-in required)")
        case .team:
            String(localized: "cloudPort.share.audience.team", defaultValue: "Your team (sign-in required)")
        case .public:
            String(localized: "cloudPort.share.audience.public", defaultValue: "Anyone with the link (public)")
        }
    }

    var symbolName: String {
        switch self {
        case .personal: "lock"
        case .team: "person.2"
        case .public: "globe"
        }
    }
}

/// Every way a port's audience changes in the app: the preview tab's share
/// control and the Ports row's Share submenu (both built by `CloudPortShareMenu`). Private by default; public
/// only after a second confirmation that names who will be able to open it.
/// Writes use the same publication API, and the same `CloudPortSharePlan`, as
/// `cmux vm share` and `cmux cloud domains publish` / `access` / `rm`.
@MainActor
enum CloudPortShareFlow {
    /// Ports whose share change is open or still writing, keyed `machine:port`.
    /// A second change while one runs would read the same "no publication yet"
    /// and create a second one.
    private static var inFlight: Set<String> = []

    /// Starts a flow unless one is already running for this port.
    /// - Returns: Whether a flow started.
    @discardableResult
    static func beginFlow(machineID: String, port: Int) -> Bool {
        inFlight.insert("\(machineID):\(port)").inserted
    }

    static func endFlow(machineID: String, port: Int) {
        inFlight.remove("\(machineID):\(port)")
    }

    /// One shared mutation path. Reads the port's publications fresh, asks the
    /// public confirmation when the change opens the port to anyone, writes, then
    /// invalidates the store so every badge and control follows.
    static func change(_ context: CloudPortShareContext, to target: CloudPortShareTarget) {
        guard let client = VMClient.shared else {
            showError(CloudPortShareError.signedOut.description)
            return
        }
        guard beginFlow(machineID: context.machineID, port: context.port) else { return }
        Task { @MainActor in
            defer { endFlow(machineID: context.machineID, port: context.port) }
            do {
                try await run(context, target: target, client: client)
            } catch let error as CloudPortShareError {
                showError(error.description)
            } catch {
                showError(String(
                    localized: "cloudPort.share.changeFailed.detail",
                    defaultValue: "The change could not be confirmed. Check the port's sharing and try again."
                ))
            }
        }
    }

    /// Copies the port's shared link (the widest publication's).
    static func copyLink(_ context: CloudPortShareContext) {
        guard let url = CloudPortSharingStore.shared.plan(machineID: context.machineID, port: context.port).primary?.url,
              !url.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    private static func run(
        _ context: CloudPortShareContext,
        target: CloudPortShareTarget,
        client: VMClient
    ) async throws {
        let store = CloudPortSharingStore.shared
        try await store.reload()
        let initial = store.plan(machineID: context.machineID, port: context.port)
        if initial.requiresPublicConfirmation(target), !confirmPublic(portLabel: context.portLabel) { return }

        var current = initial
        var lastError: Error?
        // A timeout or 503 can arrive after the server committed a mutation.
        // Re-read after every attempt and only finish once the authoritative
        // publication list satisfies the requested audience. This keeps the
        // preview control safe when a narrowing request partially succeeds.
        for attempt in 0..<3 {
            let steps = current.steps(to: target)
            if steps.isEmpty { return }
            do {
                try await execute(steps, context: context, client: client)
                try await store.reload()
                let refreshed = store.plan(machineID: context.machineID, port: context.port)
                if refreshed.steps(to: target).isEmpty { return }
                current = refreshed
            } catch let mutationError {
                lastError = mutationError
                do {
                    try await store.reload()
                } catch {
                    // The authoritative list is unavailable, so do not repeat
                    // a create/delete whose commit status is unknown.
                    store.invalidate()
                    throw mutationError
                }
                let refreshed = store.plan(machineID: context.machineID, port: context.port)
                if refreshed.steps(to: target).isEmpty { return }
                current = refreshed
                if attempt == 2 {
                    store.invalidate()
                    throw mutationError
                }
            }
        }
        // A successful read that never converged still leaves the mutation
        // outcome uncertain to the rest of the app; make the next observation
        // fetch again instead of serving this snapshot until its TTL expires.
        store.invalidate()
        throw lastError ?? CloudPortShareError.mutationDidNotConverge
    }

    /// Runs a plan's writes. Creating a public link reserves it privately first,
    /// then opens it, like `cmux cloud domains publish --access public`, so a
    /// failure never leaves it public.
    static func execute(_ steps: [CloudPortShareStep], context: CloudPortShareContext, client: VMClient) async throws {
        for step in steps {
            switch step {
            case .create(let audience):
                let teamID = try teamID(for: audience)
                let created = try await client.createPublication(
                    vmID: context.machineID,
                    port: context.port,
                    hostname: nil,
                    accessMode: audience == .public ? .personal : audience.accessMode,
                    teamID: audience == .public ? nil : teamID
                )
                if audience == .public {
                    _ = try await client.updatePublicationAccess(id: created.id, accessMode: .public, teamID: nil, confirmPublic: true)
                }
            case .update(let id, let audience):
                let teamID = try teamID(for: audience)
                _ = try await client.updatePublicationAccess(
                    id: id, accessMode: audience.accessMode, teamID: teamID, confirmPublic: audience == .public
                )
            case .delete(let id):
                try await client.deletePublication(id: id)
            }
        }
    }

    private static func teamID(for audience: CloudPortShareAudience) throws -> String? {
        guard audience == .team else { return nil }
        guard let teamID = AppDelegate.shared?.auth?.coordinator.resolvedTeamID, !teamID.isEmpty else {
            throw CloudPortShareError.signedOut
        }
        return teamID
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

    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "cloudPort.share.changeFailed", defaultValue: "Could not change who can open the port")
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "cloudPort.share.done.ok", defaultValue: "OK"))
        _ = alert.runModal()
    }
}
