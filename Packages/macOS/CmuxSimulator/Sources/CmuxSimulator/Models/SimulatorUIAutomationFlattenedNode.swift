struct SimulatorUIAutomationFlattenedNode {
    let node: SimulatorAccessibilityNode
    let path: String
    let visibleFrame: SimulatorRect?
    var descendantFrameBounds: SimulatorRect?
}
