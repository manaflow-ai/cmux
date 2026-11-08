import Foundation

extension Workspace {
    /// Plain Cloud attachment keeps the loading panel until a real remote pane
    /// replaces it. A temporary local shell would accept and then lose early input.
    func prepareCloudTerminalAttachment(command: String, deferTerminal: Bool, focus: Bool) -> UUID? {
        guard !isRetiredFromOwningTabManager else { return nil }
        if deferTerminal {
            return panels.first { $0.value.panelType == .cloudVMLoading }?.key
        }
        return replaceCloudVMLoadingSurfaceWithTerminal(workspaceId: id, initialCommand: command, focus: focus)?.id
    }
}
