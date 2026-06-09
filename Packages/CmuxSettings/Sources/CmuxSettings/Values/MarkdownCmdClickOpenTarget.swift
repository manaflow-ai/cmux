import Foundation

/// Where a Cmd-clicked file path link in the markdown viewer opens.
///
/// Plain clicks always open a new tab in the viewer's pane; this setting
/// only changes what Cmd-click does. The default is `newTab`.
public enum MarkdownCmdClickOpenTarget: String, CaseIterable, Sendable, SettingCodable {
    /// Open the file in a new tab in the same pane.
    case newTab
    /// Open the file in a split to the right, reusing an existing
    /// right-side pane when one exists.
    case splitRight
}
