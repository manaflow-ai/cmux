import CmuxTerminal

@MainActor
protocol TerminalWakeRendererRecoverable: AnyObject {
    var isRendererEffectivelyVisible: Bool { get }
    func recoverRendererAfterWake(reason: String)
}

extension TerminalSurface: TerminalWakeRendererRecoverable {}
