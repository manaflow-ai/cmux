import AppKit
import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextRemote
import CmuxNextServer
import Foundation

/// This Mac's join consent in the app (contract §5): the status from the bundled cmux-tui's acpmux
/// (`acp host join --status --json`), and the writes over a person-proof acpmux line, refused by acpmux
/// for an on from a connection that is not the person (the Full access pattern).
///
/// The write method is a stand-in: acpmux has no person-only consent method yet (only the local
/// `acpmux host consent grant|revoke` command), so ``JoinConsentPersonLine/method`` names the one
/// asked for. Until it lands acpmux answers it with an error and every write reports failure;
/// nothing is turned on.
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
    /// The person-only consent write asked of acpmux (not in acpmux yet; see the extension above).
    static let method = "_acpmux/consent_set"
    private let line: AcpmuxPersonLine

    init(_ line: AcpmuxPersonLine) {
        self.line = line
    }

    var isPerson: Bool { line.isPerson }

    func set(_ surface: JoinConsentSurface, on: Bool) async -> Bool {
        await line.call(Self.method, ["surface": surface.rawValue, "on": on]) != nil
    }

    func close() { line.close() }
}

extension JoinConsentModel {
    /// The model with its one-time sheet's panel, made on the first show.
    static func app(_ services: AppServices) -> JoinConsentModel {
        let model = JoinConsentModel(services: .app(services))
        var panel: JoinConsentAskPanel?
        model.present = { [weak model] shown in
            guard let model else { return }
            if shown, panel == nil { panel = JoinConsentAskPanel(model: model) }
            panel?.setShown(shown)
        }
        return model
    }
}
