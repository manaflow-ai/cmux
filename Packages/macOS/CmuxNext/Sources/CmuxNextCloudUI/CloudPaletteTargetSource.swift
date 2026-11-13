public import CmuxNextActions
public import CmuxNextCloud
import CmuxNextCompat
public import CmuxNextPalette
import Foundation

/// The Cloud inventory for the shared subject picker. Rust orders machines and
/// decides their recovery; this adapter reads models and supplies localized labels.
public final class CloudPaletteTargetSource: PaletteTargetSource {
    private let machines: @MainActor () -> [CloudMachine]
    private let refresh: @MainActor () async -> Void
    private let ask: @MainActor ([String: Any]) -> [String: Any]?
    private let next: any PaletteTargetSource
    private let actions: Set<ActionID>

    public init(actions: Set<ActionID>, next: any PaletteTargetSource,
                machines: @escaping @MainActor () -> [CloudMachine],
                refresh: @escaping @MainActor () async -> Void,
                ask: @escaping @MainActor ([String: Any]) -> [String: Any]?) {
        (self.actions, self.next, self.machines, self.refresh, self.ask) = (actions, next, machines, refresh, ask)
    }

    private func owns(_ kind: ActionTargetKind, _ action: ActionID) -> Bool {
        kind == .machine && actions.contains(action)
    }

    public func targets(of kind: ActionTargetKind) -> [PaletteTargetOption] { next.targets(of: kind) }

    public func targets(of kind: ActionTargetKind, for action: ActionID) -> [PaletteTargetOption] {
        guard owns(kind, action) else { return next.targets(of: kind, for: action) }
        return Self.options(machines: machines(), desktop: action == "cloudOpenDesktop", ask: ask)
    }

    public func targetRefresh(of kind: ActionTargetKind, for action: ActionID) -> (@MainActor () async -> [PaletteTargetOption])? {
        guard owns(kind, action) else { return next.targetRefresh(of: kind, for: action) }
        return { [weak self] in
            guard let self else { return [] }
            await refresh()
            guard !Task.isCancelled else { return [] }
            return targets(of: kind, for: action)
        }
    }

    public func targetUpdates(of kind: ActionTargetKind, for action: ActionID) -> (@MainActor () -> AsyncStream<[PaletteTargetOption]>)? {
        guard owns(kind, action) else { return next.targetUpdates(of: kind, for: action) }
        return { [weak self] in
            let (stream, continuation) = AsyncStream.makeStream(of: [PaletteTargetOption].self, bufferingPolicy: .bufferingNewest(1))
            // task-owner: this open picker observes machine changes until its page closes.
            // main-hop-allow: an Observation subscription, not view work: each inventory change emits one
            // cached snapshot to the palette's scheduled provider; the consumer cancels it on page close.
            let task = Task { @MainActor [weak self] in
                guard let self else { continuation.finish(); return }
                await refresh()
                for await records in ObservationStream({ self.machines() }) {
                    guard !Task.isCancelled else { break }
                    continuation.yield(Self.options(machines: records, desktop: action == "cloudOpenDesktop", ask: ask))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
            return stream
        }
    }

    public func title(of target: ActionTargetRef) -> String? {
        if target.kind == .machine, let machine = machines().first(where: { $0.id == target.id }) { return machine.shownName }
        return next.title(of: target)
    }

    public func currentDescription(of target: ActionTargetRef) -> String? { next.currentDescription(of: target) }

    public static func options(machines: [CloudMachine], desktop: Bool, ask: ([String: Any]) -> [String: Any]?) -> [PaletteTargetOption] {
        let facts: [[String: Any]] = machines.map { machine in
            ["id": machine.id, "title": machine.shownName.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? Words.machine,
             "status": machine.shownStatus.rawValue, "desktop": machine.opensCarrierDesktop]
        }
        let answer = ask(["desktop": desktop, "machines": facts])
        let rows = answer?["rows"] as? [[String: Any]] ?? []
        return rows.compactMap { row -> PaletteTargetOption? in
            guard let id = row["id"] as? String, let title = row["title"] as? String else { return nil }
            let state = row["state"] as? String, intent = row["intent"] as? String
            let recovery = intent == "startDesktop"
                ? PaletteTargetRecovery(action: "cloudSetupDesktop", title: Words.setup, target: ActionTargetRef(kind: .machine, id: id))
                : intent == "createDesktop" ? PaletteTargetRecovery(action: "newCloudMachine", title: Words.create) : nil
            return PaletteTargetOption(id: id, title: state == "empty" ? Words.create : title,
                                       subtitle: Words.state(state), symbol: state == "empty" ? "plus" : "desktopcomputer",
                                       isEnabled: intent != nil, accessory: desktop && state == "resume" ? Words.resume : nil, recovery: recovery)
        }
    }

    private enum Words {
        static var machine: String { String(localized: "cloud.palette.machine", defaultValue: "Cloud Machine", table: "CloudPalette", bundle: .module) }
        static var create: String { String(localized: "cloud.palette.createDesktop", defaultValue: "Create desktop machine", table: "CloudPalette", bundle: .module) }
        static var setup: String { String(localized: "cloud.palette.setupDesktop", defaultValue: "Set up desktop", table: "CloudPalette", bundle: .module) }
        static var resume: String { String(localized: "cloud.palette.resumeDesktop", defaultValue: "Resume and open", table: "CloudPalette", bundle: .module) }
        static func state(_ state: String?) -> String? {
            switch state {
            case "ready": nil
            case "resume": String(localized: "cloud.palette.paused", defaultValue: "Paused", table: "CloudPalette", bundle: .module)
            case "desktopUnavailable": String(localized: "cloud.palette.desktopUnavailable", defaultValue: "Desktop service unavailable", table: "CloudPalette", bundle: .module)
            case "starting": String(localized: "cloud.palette.starting", defaultValue: "Starting…", table: "CloudPalette", bundle: .module)
            case "unavailable": String(localized: "cloud.palette.unavailable", defaultValue: "Machine unavailable", table: "CloudPalette", bundle: .module)
            default: nil
            }
        }
    }
}
