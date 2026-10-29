import AppKit
import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextRemote
import CmuxNextServer
import Foundation

/// This Mac's join consent in the app (contract §5): the join status from the bundled cmux-tui's acpmux
/// (`acp host join --status --json`), and the consent record over a person-proof acpmux line
/// (`_acpmux/machine_consent_get` and `_set`, under `machine-consent-v1`). acpmux changes the record only
/// for a connection proven as the person on its local socket (the Full access pattern); no command line
/// can, so the app calls it directly.
extension JoinConsentServices {
    static let askShownKey = "cmux.join.consentAskShown"

    static func app(_ services: AppServices) -> JoinConsentServices {
        let cli = (try? DaemonLauncher.resolveBinary(bundle: .main, environment: ProcessInfo.processInfo.environment))
            .map { HostCLI(binary: $0, environment: SSHService.environment) }
        return JoinConsentServices(
            status: {
                #if DEBUG
                if let fixture = DebugJoinConsent.status { return fixture }
                #endif
                guard let data = await cli?.json(["acp", "host", "join", "--status", "--json"], deadline: .seconds(10), label: "join status")
                else { return nil }
                return JoinStatus.parse(data)
            },
            openLine: { [weak services] in
                #if DEBUG
                if DebugJoinConsent.status != nil { return DebugJoinConsent.line }
                #endif
                guard let services, let environment = QuitAgents.environment(services),
                      let line = await AcpmuxPersonLine.open(environment) else { return nil }
                return JoinConsentPersonLine(line)
            },
            enabled: { [weak services] in services?.settings?.snapshot.machineJoin == true },
            askShown: { UserDefaults.standard.bool(forKey: askShownKey) },
            markAskShown: { UserDefaults.standard.set(true, forKey: askShownKey) })
    }
}

/// ``JoinConsentLine`` over the app's ``AcpmuxPersonLine``.
@MainActor
final class JoinConsentPersonLine: JoinConsentLine {
    static let capability = "machine-consent-v1"
    private let line: AcpmuxPersonLine

    init(_ line: AcpmuxPersonLine) {
        self.line = line
    }

    var isPerson: Bool { line.isPerson }
    var supportsConsent: Bool { line.capabilities.contains(Self.capability) }

    func read() async -> JoinConsentRecord? {
        (await line.call("_acpmux/machine_consent_get", [:])).flatMap(JoinConsentRecord.parse)
    }

    func set(_ surface: JoinConsentSurface, granted: Bool) async -> Bool {
        await line.call("_acpmux/machine_consent_set", ["surface": surface.rawValue, "granted": granted]) != nil
    }

    func close() { line.close() }
}

extension JoinConsentModel {
    /// The model with its one-time sheet's panel, made on the first show. It reads again each time the app
    /// comes forward (a read with the Labs switch off reads nothing), so a refusal acpmux recorded meanwhile
    /// shows the sheet; the loop ends with the model.
    static func app(_ services: AppServices) -> JoinConsentModel {
        let model = JoinConsentModel(services: .app(services))
        var panel: JoinConsentAskPanel?
        model.present = { [weak model] shown in
            guard let model else { return }
            if shown, panel == nil { panel = JoinConsentAskPanel(model: model) }
            panel?.setShown(shown)
        }
        // task-owner: lives as long as the model; one read per activation
        Task { [weak model] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                guard let model else { return }
                await model.refresh()
            }
        }
        return model
    }
}
