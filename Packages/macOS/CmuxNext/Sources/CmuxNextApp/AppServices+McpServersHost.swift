import CmuxNextAgentPane
import Foundation

extension AppServices: McpServersHost {
    var mcpServersEnvironment: AcpmuxEnvironment? { QuitAgents.environment(self) }
    func mcpServersShowPage(focus: Bool) -> Bool { pages.show(InternalPageID(rawValue: McpServersCoordinator.pageID), in: windows.active, focus: focus) != nil }
    func mcpServersPageIsOpen() -> Bool { pageIsOpen(InternalPageID(rawValue: McpServersCoordinator.pageID)) }
    func mcpServersOpenBrowserTab(_ url: URL) { _ = windows.active?.focusedPane?.newBrowserTab(url: url) }
}
