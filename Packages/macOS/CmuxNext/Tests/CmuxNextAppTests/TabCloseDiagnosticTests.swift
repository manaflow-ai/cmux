import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDaemonService
import Foundation
import Testing

/// A close failure must be attributable without showing daemon internals in a notice.
@MainActor
@Suite struct TabCloseDiagnosticTests {
    @Test(arguments: [TabKind.pty, .browser, .remoteTerminal, .conversation])
    func theLoggedCommandNamesTheTabKindAndDirectEntrypoint(_ kind: TabKind) {
        let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 7), kind: kind))
        let command = DaemonService.closeCommand(for: tab, reaps: true)
        #expect(command.label.contains("tab_kind=\(kind.rawValue)"))
        #expect(command.label.contains("entrypoint=direct"))
    }

    @Test func aMenuCloseKeepsItsEntrypointInTheLoggedCommand() {
        let scope = ActionRunScope(origin: .user, allowsViewChange: true, menuPick: true)
        ActionRunScope.$current.withValue(scope) {
            let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 8), kind: .browser))
            let command = DaemonService.closeCommand(for: tab, reaps: true)
            #expect(command.label.contains("tab_kind=browser"))
            #expect(command.label.contains("entrypoint=menu"))
        }
    }

    @Test(arguments: [TabKind.pty, .browser, .remoteTerminal, .conversation],
          ["disconnected", "refused", "timeout"])
    func theLogLineKeepsTheCloseContextAndErrorKind(_ kind: TabKind, _ errorKind: String) {
        let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 9), kind: kind))
        let command = DaemonService.closeCommand(for: tab, reaps: true)
        let error = error(for: errorKind)
        let line = CommandFailureDiagnostic(label: command.label, error: error).message
        #expect(line.contains("tab_kind=\(kind.rawValue)"))
        #expect(line.contains("entrypoint=direct"))
        #expect(line.contains("error_kind=\(errorKind)"))
        #expect(line.contains(error.description))
        #expect(line.contains("outcome unknown") == (errorKind == "timeout"))
    }

    @Test(arguments: [ActionOrigin.user, .cli, .mcp, .script, .remote, .page])
    func actionsKeepTheirOrigin(_ origin: ActionOrigin) {
        ActionRunScope.$current.withValue(ActionRunScope(origin: origin, allowsViewChange: false)) {
            let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 10), kind: .conversation))
            let command = DaemonService.closeCommand(for: tab, reaps: true)
            let line = CommandFailureDiagnostic(label: command.label, error: error(for: "refused")).message
            #expect(line.contains("entrypoint=action"))
            #expect(line.contains("origin=\(origin.rawValue)"))
            #expect(line.contains("error_kind=refused"))
        }
    }

    @Test(arguments: ["disconnected", "refused", "timeout"])
    func aBatchRetainsDistinctTabKindsWithoutRepeatingIdenticalContext(_ errorKind: String) {
        let commands = [TabKind.pty, .browser, .pty].map { kind in
            DaemonService.closeCommand(for: TabModel(TabSnapshot(surface: SurfaceID(rawValue: 11), kind: kind)), reaps: true)
        }
        let label = DaemonService.batchCloseLabel(commands)
        let line = CommandFailureDiagnostic(label: label, error: error(for: errorKind)).message
        #expect(line.contains("tab_kind=pty entrypoint=direct"))
        #expect(line.contains("tab_kind=browser entrypoint=direct"))
        #expect(line.contains("error_kind=\(errorKind)"))
        #expect(label.components(separatedBy: "tab_kind=pty").count == 2)
    }

    @Test(arguments: [DaemonError.notConnected, .connectionClosed(reason: "test disconnect"), .daemonShutdown,
                      .connectFailed(path: "/test/socket", errno: 61)])
    func lostConnectionsAreNotReportedAsRefusals(_ error: DaemonError) {
        #expect(CommandFailureDiagnostic(label: "close-surface", error: error).message.contains("error_kind=disconnected"))
    }

    @Test func anOfflineHiddenCloseLogsBeforeReturningTheExistingRefusal() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let context = AppActionContext(services: services)
        let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 12), kind: .browser))
        let command = DaemonService.closeCommand(for: tab, reaps: true)
        var lines: [String] = []
        let expectedRefusal = services.registry.capturingRefusal { _ = context.connection() }
        let refusal = services.registry.capturingRefusal {
            context.send(command.label, logFailure: { label, error in
                lines.append(CommandFailureDiagnostic(label: label, error: error).message)
            }) { _ in Issue.record("An offline close must not send the command") }
        }
        #expect(expectedRefusal != nil)
        #expect(refusal == expectedRefusal)
        #expect(lines.count == 1)
        #expect(lines.first?.contains("tab_kind=browser entrypoint=direct") == true)
        #expect(lines.first?.contains("error_kind=disconnected") == true)
    }

    private func error(for kind: String) -> DaemonError {
        switch kind {
        case "timeout": .timedOut("close-tabs")
        case "disconnected": .notConnected
        default: .command(cmd: "close-tabs", message: "home tab stays", code: "home_tab_pinned", details: nil, retryable: false)
        }
    }
}
