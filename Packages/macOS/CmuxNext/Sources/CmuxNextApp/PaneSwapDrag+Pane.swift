import CmuxNextActions
import CmuxNextBridge

extension PaneSwapDrag {
    /// A pane's drag: a drop runs Swap with Session with the pane under the pointer, the swap's one path (shown in the drop's turn).
    convenience init(pane: PaneController) {
        self.init(strip: pane.view.stripView, pane: pane.layoutPaneID, layout: { [weak pane] in pane?.workspace?.layoutView },
                  dragKey: { [weak pane] in pane?.pane.tabs.first?.id },
                  move: { [weak pane] target in if let pane { PaneMoves.move(pane, to: target) } },
                  swap: { [weak pane] _, to in
                      guard let pane, let other = pane.workspace?.panes[to] else { return }
                      let swap = ActionInvocation(target: ActionTargetRef(kind: .pane, id: pane.paneKey), arguments: ["pane": .target(ActionTargetRef(kind: .pane, id: other.paneKey))])
                      _ = pane.services.registry.perform("palette.swapWithSession", invocation: swap.onMachine(pane.daemon.machineID))
                  })
    }
}
