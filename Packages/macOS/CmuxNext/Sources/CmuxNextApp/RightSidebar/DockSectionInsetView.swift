import AppKit

/// Pads one view by `inset` on every side (the SwiftUI `.padding` the
/// sections had), so a stack can stretch the box while the content keeps
/// its own width.
final class DockSectionInsetView: NSView {
    /// - Parameter fills: The content takes the box's full width (a wrapping label); else it keeps its own.
    init(_ content: NSView, inset: CGFloat, fills: Bool = false) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            fills ? content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset)
                : content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),
            content.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
