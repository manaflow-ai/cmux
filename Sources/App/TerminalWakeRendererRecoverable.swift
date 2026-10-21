import CmuxTerminal

@MainActor
protocol TerminalWakeRendererRecoverable: AnyObject {
    var isRendererPortalVisible: Bool { get }
    func recoverRendererAfterWake(reason: String)
}

extension TerminalSurface: TerminalWakeRendererRecoverable {}
