import CmuxNextBridge
import CmuxNextBridgeUI

extension AppServices {
    /// This Mac's tabs whose agent runs a turn (acpmux, hooks or an OSC 7501
    /// `working` record): Sleepy Mode's "Agents working" line.
    func workingAgentTabCount() -> Int {
        let tabs = daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
        var seen = Set<String>()
        return tabs.filter { seen.insert($0.id).inserted && StatusMapping.shared.isWorking(tabs: [$0]) }.count
    }
}
