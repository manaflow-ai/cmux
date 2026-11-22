import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextDaemon
import Foundation
import Testing

/// cx-8g25: a raw daemon capability id ("needs daemon capability
/// profiles-v1") reached the user as a toast. No user-visible string may
/// name a capability: an action that needs one is disabled through the one
/// capability gate (`DaemonService.missingCapabilityMessage`) with a reason
/// that says what to do, and invoking a disabled action shows nothing.
@MainActor
struct CapabilityRefusalTests {
    /// A capability-id-shaped token (`profiles-v1`, `tab-groups-v12`), or
    /// the word the old reasons used.
    static func namesCapability(_ text: String) -> Bool {
        text.contains(/[a-z0-9]-v[0-9]+\b/) || text.localizedCaseInsensitiveContains("capabilit")
    }

    /// The capability gate's reasons: what the user can do, never an id.
    static var gateReasons: Set<String> {
        [RefusalStrings.daemonConnecting, RefusalStrings.daemonUnavailable, RefusalStrings.restartToUpdateDaemon, RefusalStrings.notInThisVersion,
         RefusalStrings.personalStateLoading, RefusalStrings.updateCloudMachine]
    }

    /// A run refused with one of the gate's reasons.
    static func refusedByGate(_ outcome: ControlActionOutcome) -> Bool {
        if case .refused(let reason) = outcome { return gateReasons.contains(reason) }
        return false
    }

    /// Every capability this app knows by name, plus ids the app used as
    /// literals for features with no daemon half.
    static var knownCapabilities: [String] {
        let shared = DaemonCapabilities.shared
        return shared.required + shared.optional + shared.unservedByBundledDaemon
            + ["closed-history-v1", "layout-templates-v1", "remote-workspaces-v1", "workspace-checklist-v1", "remote-ssh-tabs", "resume-command"]
    }

    /// Every compiled string table of the app bundle, in English.
    private static func englishTables() throws -> [String: [String: String]] {
        let lproj = try #require(Bundle.module.path(forResource: "en", ofType: "lproj"), "no en.lproj")
        let files = try FileManager.default.contentsOfDirectory(atPath: lproj).filter { $0.hasSuffix(".strings") }
        var tables: [String: [String: String]] = [:]
        for file in files {
            tables[file] = NSDictionary(contentsOf: URL(fileURLWithPath: lproj).appending(path: file)) as? [String: String] ?? [:]
        }
        return tables
    }

    @Test func noUserVisibleStringNamesACapability() throws {
        let tables = try Self.englishTables()
        try #require(tables.keys.contains("Refusals.strings"), "the string catalogs were not compiled: \(tables.keys.sorted())")
        var offenders: [String] = []
        for (table, strings) in tables {
            for (key, value) in strings where Self.namesCapability(value) { offenders.append("\(table) \(key): \(value)") }
        }
        #expect(offenders.isEmpty, "\(offenders.sorted())")
    }

    @Test func capabilityRefusalBuildersNeverShowTheId() {
        for capability in Self.knownCapabilities {
            let texts = [RefusalStrings.needsDaemonCapability(capability), ActionFailure.needsDaemonCapability(capability).message,
                         ActionFailure.needsAppCapability(capability).message]
            for text in texts { #expect(!Self.namesCapability(text), "\(capability): \(text)") }
            // This tree's daemon serves it: a running daemon without it is older.
            let expected = DaemonCapabilities.shared.isServedByBundledDaemon(capability) ? RefusalStrings.restartToUpdateDaemon
                : RefusalStrings.notInThisVersion
            #expect(RefusalStrings.needsDaemonCapability(capability) == expected, "\(capability)")
        }
    }

    /// Every catalog action's disabled reason, with no daemon, with a daemon
    /// that serves nothing, and with a daemon that serves this tree's set.
    @Test(arguments: [0, 1, 2])
    func noActionReasonNamesACapability(_ state: Int) {
        let services = ActionBindingCoverageTests.boundServices()
        if state == 1 { services.daemon.store.noteHandshake(DaemonIdentity(capabilities: [], generation: "g1")) }
        if state == 2 {
            let shared = DaemonCapabilities.shared
            services.daemon.store.noteHandshake(DaemonIdentity(capabilities: shared.required + shared.optional, generation: "g1"))
        }
        var offenders: [String] = []
        for descriptor in ActionCatalog.all {
            guard let reason = services.registry.unavailableReason(for: descriptor.id), Self.namesCapability(reason) else { continue }
            offenders.append("\(descriptor.id.rawValue): \(reason)")
        }
        #expect(offenders.isEmpty, "\(offenders.sorted())")
    }

    /// A connected daemon without `profiles-v1` (an older build): the
    /// workspace group actions are disabled with a reason that names no id,
    /// and a keyboard or menu run of one does nothing and shows no notice.
    @Test func aGatedActionIsDisabledAndNeverNotifies() {
        let services = ActionBindingCoverageTests.boundServices()
        services.daemon.store.noteHandshake(DaemonIdentity(capabilities: DaemonCapabilities.shared.required, generation: "g1"))
        var notices: [String] = []
        services.registry.refusalObserver = { reason, _ in notices.append(reason) }
        let target = ActionTargetRef(kind: .workspaceGroup, id: "grp_1")
        for id: ActionID in ["workspaceGroup.collapse", "newWorkspaceGroup", "nextWorkspaceGroup"] {
            #expect(!services.registry.canPerform(id), "\(id)")
            let reason = services.registry.unavailableReason(for: id)
            #expect(reason != nil && !Self.namesCapability(reason ?? ""), "\(id): \(reason ?? "nil")")
            #expect(!services.registry.perform(id, invocation: ActionInvocation(target: target)), "\(id)")
        }
        #expect(notices.isEmpty, "\(notices)")
    }
}
