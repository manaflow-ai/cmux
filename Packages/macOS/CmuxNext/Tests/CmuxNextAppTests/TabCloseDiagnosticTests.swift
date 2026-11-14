import CmuxNextActions
import CmuxNextDaemon
@testable import CmuxNextDaemonService
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
}
