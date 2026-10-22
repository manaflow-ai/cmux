public import AppKit

extension NSView {
    /// This view in a clear box as wide as the box is laid out, `leading` and `trailing` in from
    /// the box's edges: a menu panel's separator or swatch row on the menu grid (`MenuMetrics`) in
    /// a vertical stack whose rows span the highlight, as the panel editors lay theirs out.
    public func inMenuGridBox(leading: CGFloat, trailing: CGFloat) -> NSView {
        let box = NSView()
        translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(self)
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: leading),
            trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -trailing),
            topAnchor.constraint(equalTo: box.topAnchor),
            bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        return box
    }
}
