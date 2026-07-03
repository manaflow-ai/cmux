#if os(iOS)
import CMUXMobileCore
import CmuxMobileShellModel

struct TerminalLoadingDiagnosticsModel: Equatable {
    let title: String
    let message: String
    let rows: [TerminalLoadingDiagnosticsRow]
    let isLoading: Bool

    init(
        workspaceName: String,
        terminalCount: Int,
        macName: String?,
        connectionStatus: MobileMacConnectionStatus,
        tailnetStatus: TailnetStatus?,
        activeRoute: CmxAttachRoute?,
        storedRouteDescription: String?,
        connectionError: String?,
        connectionErrorGuidance: String?,
        loadingTimedOut: Bool = false
    ) {
        self = TerminalLoadingDiagnosticsModelBuilder(
            workspaceName: workspaceName,
            terminalCount: terminalCount,
            macName: macName,
            connectionStatus: connectionStatus,
            tailnetStatus: tailnetStatus,
            activeRoute: activeRoute,
            storedRouteDescription: storedRouteDescription,
            connectionError: connectionError,
            connectionErrorGuidance: connectionErrorGuidance,
            loadingTimedOut: loadingTimedOut
        ).makeModel()
    }

    init(title: String, message: String, rows: [TerminalLoadingDiagnosticsRow], isLoading: Bool) {
        self.title = title
        self.message = message
        self.rows = rows
        self.isLoading = isLoading
    }
}
#endif
