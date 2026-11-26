import CmuxNextActions
import Foundation

extension AppActionContext {
    /// The folder Open Files as Pane and Open Find as Pane open on, for the palette, the CLI
    /// (`cmux pane open-files-as [--pane P] [--path DIR]`) and MCP alike. The run's `path` wins
    /// (`~` expanded; a relative one under the pane's folder, else home); else the folder of the
    /// named pane's local terminal, else the active window's focused one. The inner nil means
    /// home. The outer nil means the run named a pane no window shows: it was refused.
    func openAsPaneFolder(_ invocation: ActionInvocation) -> URL?? {
        let paneFolder: URL?
        if namesPane(invocation) {
            guard let pane = paneController(invocation) else { return nil }
            paneFolder = services.fileExplorers.folder(of: pane)
        } else {
            paneFolder = services.windows.active.flatMap { services.fileExplorers.folder(focusedIn: $0) }
        }
        guard let path = invocation["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return .some(paneFolder)
        }
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return .some(URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL) }
        let base = paneFolder ?? FileManager.default.homeDirectoryForCurrentUser
        return .some(base.appendingPathComponent(expanded, isDirectory: true).standardizedFileURL)
    }
}
