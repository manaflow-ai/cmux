import AppKit
import CmuxNextDesign
import QuartzCore

/// Hard-edge chrome (`chrome.hardEdge`): the pill takes the window's one shape, cut at 45° on its
/// top-leading and bottom-trailing corners like the content card and the selected workspace row,
/// and the selected tab carries the value's marks (`HardEdge.selectedMarks`). Off: the rounded pill and no marks.
extension TabCell {
    private static let marksName = "cmux.tab.hardEdgeMarks"

    /// The marks layer, made on first use beside the pill (above it, under the icon and title).
    private func hardEdgeMarks(create: Bool) -> CAShapeLayer? {
        if let existing = layer.sublayers?.first(where: { $0.name == Self.marksName }) as? CAShapeLayer { return existing }
        guard create else { return nil }
        let marks = CAShapeLayer()
        marks.name = Self.marksName
        marks.actions = Self.noActions
        marks.lineCap = .butt
        layer.insertSublayer(marks, above: backgroundLayer)
        return marks
    }

    /// Cuts the pill and places the marks for the pill's current frame (`layoutParts`).
    func layoutHardEdge() {
        let style = metrics.hardEdge
        let pill = backgroundLayer.frame
        guard let mask = style.fillMask(CGRect(origin: .zero, size: pill.size)) else {
            backgroundLayer.mask = nil
            hardEdgeMarks(create: false)?.removeFromSuperlayer()
            return
        }
        backgroundLayer.cornerRadius = 0 // square where not cut: no curve anywhere
        let shape = backgroundLayer.mask as? CAShapeLayer ?? CAShapeLayer()
        shape.actions = Self.noActions
        shape.frame = CGRect(origin: .zero, size: pill.size)
        shape.path = mask
        if backgroundLayer.mask !== shape { backgroundLayer.mask = shape }
        guard let path = style.selectedMarks(pill) else {
            hardEdgeMarks(create: false)?.removeFromSuperlayer()
            return
        }
        let marks = hardEdgeMarks(create: true)
        marks?.frame = bounds
        marks?.path = path
        applyHardEdgeColors()
    }

    /// Shows the marks on the selected tab only, in the accent (`applyColors`, inside the theme scope).
    func applyHardEdgeColors() {
        guard let marks = hardEdgeMarks(create: false) else { return }
        marks.isHidden = !isSelected
        marks.fillColor = HardEdge.accent.cgColor
    }
}
