import AppKit
import CmuxNextDesign

/// `Toggle`: a settings row, its `label` leading and a mini switch trailing (the app's own switch
/// rows). `value` is the state. With `onChange` a flip shows at once and sends `change {value}`, and
/// the next `value` the app sends wins; without it the switch only shows the app's value, disabled.
final class AppSceneToggleNSView: AppSceneNodeNSView {
    private let label = ChromeLabel(labelWithString: "")
    private let control = NSSwitch()

    override init(id: String, node: AppSceneNode) {
        super.init(id: id, node: node)
        control.controlSize = .mini
        control.target = self
        control.action = #selector(flipped)
        label.font = Typography.body
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        addSubview(control)
    }

    override func configure(_ node: AppSceneNode) {
        super.configure(node)
        label.stringValue = node.string("label") ?? ""
        label.isHidden = node.string("label") == nil
        control.state = node.flag("value") ? .on : .off
        control.isEnabled = node.flag("onChange") && !node.flag("disabled")
        control.setAccessibilityLabel(node.string("label"))
    }

    @objc private func flipped() {
        guard node.flag("onChange") else { return }
        send("change", ["value": .bool(control.state == .on)])
    }

    override var contentNaturalWidth: CGFloat? {
        label.isHidden ? control.fittingSize.width : nil
    }

    override func contentHeight(width: CGFloat) -> CGFloat {
        max(control.fittingSize.height, label.isHidden ? 0 : ceil(label.naturalSize.height))
    }

    override func layoutContent(in rect: CGRect) {
        let size = control.fittingSize
        control.frame = CGRect(x: rect.maxX - size.width, y: rect.midY - size.height / 2, width: size.width, height: size.height).integral
        let height = ceil(label.naturalSize.height)
        label.frame = CGRect(x: rect.minX, y: rect.midY - height / 2, width: max(0, control.frame.minX - Metrics.space2 - rect.minX),
                             height: height).integral
    }

    override func paint() { label.textColor = Palette.textPrimary }
}
