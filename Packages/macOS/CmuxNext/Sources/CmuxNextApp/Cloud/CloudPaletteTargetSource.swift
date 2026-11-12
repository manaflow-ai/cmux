import CmuxNextActions
import CmuxNextCloud
import CmuxNextDaemonService
import CmuxNextPalette
import Foundation

/// The Cloud inventory for the shared subject picker. Rust orders machines and
/// decides their recovery; this adapter reads models and supplies localized labels.
final class CloudPaletteTargetSource: PaletteTargetSource {
    private unowned let services: AppServices
    private let next: any PaletteTargetSource
    private let actions: Set<ActionID>

    init(services: AppServices, next: any PaletteTargetSource) {
        self.services = services
        self.next = next
        actions = Set(services.registry.descriptors.filter { $0.category == .cloud && $0.paletteTarget == .machine }.map(\.id))
    }

    private func owns(_ kind: ActionTargetKind, _ action: ActionID) -> Bool {
        kind == .machine && actions.contains(action)
    }

    func targets(of kind: ActionTargetKind) -> [PaletteTargetOption] { next.targets(of: kind) }

    func targets(of kind: ActionTargetKind, for action: ActionID) -> [PaletteTargetOption] {
        guard owns(kind, action) else { return next.targets(of: kind, for: action) }
        return Self.options(machines: services.machines.cloud.map(\.machine), desktop: action == "cloudOpenDesktop")
    }

    func targetRefresh(of kind: ActionTargetKind, for action: ActionID) -> (@MainActor () async -> [PaletteTargetOption])? {
        guard owns(kind, action) else { return next.targetRefresh(of: kind, for: action) }
        return { [weak self] in
            guard let self else { return [] }
            _ = await services.cloud.refresh()
            guard !Task.isCancelled else { return [] }
            return targets(of: kind, for: action)
        }
    }

    func targetUpdates(of kind: ActionTargetKind, for action: ActionID) -> (@MainActor () -> AsyncStream<[PaletteTargetOption]>)? {
        owns(kind, action) ? nil : next.targetUpdates(of: kind, for: action)
    }

    func title(of target: ActionTargetRef) -> String? {
        if target.kind == .machine, let session = services.machines.session(target.id) { return session.machine.displayName }
        return next.title(of: target)
    }

    func currentDescription(of target: ActionTargetRef) -> String? { next.currentDescription(of: target) }

    static func options(machines: [CloudMachine], desktop: Bool) -> [PaletteTargetOption] {
        let facts: [[String: Any]] = machines.map { machine in
            ["id": machine.id, "title": machine.displayName ?? Words.machine,
             "status": machine.shownStatus.rawValue, "desktop": machine.opensCarrierDesktop]
        }
        let answer = CloudHandlerRules().ask("cloud_handler_palette_targets", ["desktop": desktop, "machines": facts])
        let rows = answer?["rows"] as? [[String: Any]] ?? []
        var options = rows.compactMap { row -> PaletteTargetOption? in
            guard let id = row["id"] as? String, let title = row["title"] as? String else { return nil }
            let state = row["state"] as? String, intent = row["intent"] as? String
            let recovery = intent == "createDesktop" ? PaletteTargetRecovery(action: "newCloudMachine", title: Words.create) : nil
            return PaletteTargetOption(id: id, title: title, subtitle: Words.state(state), symbol: "desktopcomputer",
                                       isEnabled: intent != nil, accessory: desktop && state == "resume" ? Words.resume : nil, recovery: recovery)
        }
        // Creation remains available when the account has no machines yet.
        if desktop && options.isEmpty {
            options.append(PaletteTargetOption(id: "create-desktop", title: Words.create, symbol: "plus",
                                               recovery: PaletteTargetRecovery(action: "newCloudMachine", title: Words.create)))
        }
        return options
    }

    private enum Words {
        static var machine: String { String(localized: "cloud.palette.machine", defaultValue: "Cloud Machine", bundle: .module) }
        static var create: String { String(localized: "cloud.palette.createDesktop", defaultValue: "Create desktop machine", bundle: .module) }
        static var resume: String { String(localized: "cloud.palette.resumeDesktop", defaultValue: "Resume and open", bundle: .module) }
        static func state(_ state: String?) -> String? {
            switch state {
            case "ready": nil
            case "resume": String(localized: "cloud.palette.paused", defaultValue: "Paused", bundle: .module)
            case "imageMissingDesktop": String(localized: "cloud.palette.imageMissingDesktop", defaultValue: "This image has no desktop", bundle: .module)
            case "starting": String(localized: "cloud.palette.starting", defaultValue: "Starting…", bundle: .module)
            case "unavailable": String(localized: "cloud.palette.unavailable", defaultValue: "Machine unavailable", bundle: .module)
            default: nil
            }
        }
    }
}
