import AppKit

struct SimulatorAccessibilityFrameKey: Hashable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    init(_ rect: NSRect) {
        x = Int(rect.origin.x.rounded())
        y = Int(rect.origin.y.rounded())
        width = Int(rect.width.rounded())
        height = Int(rect.height.rounded())
    }
}
