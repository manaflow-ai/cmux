import CmuxNextActions
import CmuxNextWindowRules
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
        // Rust's `handlers_verbs::pane_folder`; `~user` is NSString's to expand.
        let path = invocation["path"]?.stringValue.map { $0.hasPrefix("~") && !$0.hasPrefix("~/") && $0 != "~" ? ($0 as NSString).expandingTildeInPath : $0 }
        let folder = WindowRules().paneFolder(path: path, paneFolder: paneFolder?.path, home: FileManager.default.homeDirectoryForCurrentUser.path)
        return .some(folder.map { URL(fileURLWithPath: $0, isDirectory: true) })
    }
}
