import Foundation

extension AgentPaneView {
    /// Pushes the opt-in live-tree experiment to the agent page.
    func applyLiveTree() {
        deliver([.liveTree(liveTree)], scripts: ["window.cmuxAcpmuxBridge?.applyLiveTree?.(\(liveTree));"])
    }
}
