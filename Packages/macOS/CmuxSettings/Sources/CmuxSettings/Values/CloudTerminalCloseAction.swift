import Foundation

/// What closing a pane that shows a cloud terminal does to the terminal on its
/// machine (`app.closeCloudTerminal`). The pane always goes away; the terminal
/// either keeps running (detach) or its process ends (kill).
public enum CloudTerminalCloseAction: String, CaseIterable, Sendable, SettingCodable {
    /// Ask on every close: Detach, Kill Process, or Cancel.
    case ask
    /// Close the pane and leave the terminal running on the machine.
    case detach
    /// End the terminal's process on the machine, then close the pane.
    case kill
}
