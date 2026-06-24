import AppKit
import CmuxSettings

/// A scroll-fixed badge watermark rendered on top of a terminal surface, in the
/// spirit of iTerm2's session badge.
///
/// The view is a transparent, click-through container (its ``hitTest(_:)``
/// returns `nil`, so pointer events fall through to the terminal) holding a
/// single multi-line label. It is added as a direct subview of the
/// `GhosttySurfaceScrollView` and pinned to that view's bounds, so it stays
/// fixed regardless of scroll position or scrollback volume.
///
/// All appearance is driven by ``apply(configuration:text:)``: the host reads a
/// ``TerminalBadgeConfiguration`` snapshot and the rendered badge text and hands
/// both here. The view does no settings or model access of its own.
final class TerminalBadgeOverlayView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var labelConstraints: [NSLayoutConstraint] = []
    private var currentPosition: BadgePosition?

    /// Horizontal/vertical inset from the surface edges, in points.
    private static let edgeInset: CGFloat = 12

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        translatesAutoresizingMaskIntoConstraints = false

        label.translatesAutoresizingMaskIntoConstraints = false
        label.isEditable = false
        label.isSelectable = false
        label.isBezeled = false
        label.drawsBackground = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        label.alignment = .right
        // Decorative watermark: never expose it to assistive tech as content the
        // user can act on; the terminal itself carries the real content.
        label.setAccessibilityElement(false)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Click-through: the badge is decorative and must never intercept pointer
    /// events destined for the terminal surface beneath it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override var acceptsFirstResponder: Bool { false }

    /// Applies a configuration snapshot and rendered badge `text`.
    ///
    /// Hides the view when the badge is disabled or the text is empty. Otherwise
    /// updates the label's string, font, color, opacity, alignment, and anchor
    /// position. Position constraints are only rebuilt when the anchor changes.
    ///
    /// - Parameters:
    ///   - configuration: The current badge appearance snapshot.
    ///   - text: The rendered badge string for this surface.
    func apply(configuration: TerminalBadgeConfiguration, text: String) {
        guard configuration.enabled, !text.isEmpty else {
            isHidden = true
            return
        }
        isHidden = false
        label.stringValue = text
        label.font = NSFont.systemFont(ofSize: configuration.fontSize, weight: .semibold)
        label.textColor = configuration.color ?? NSColor.textColor
        label.alphaValue = configuration.opacity
        label.alignment = Self.alignment(for: configuration.position)
        applyPositionIfNeeded(configuration.position)
    }

    /// Rebuilds the label's anchor constraints when the configured position
    /// changes; a no-op when the anchor is unchanged.
    private func applyPositionIfNeeded(_ position: BadgePosition) {
        guard position != currentPosition else { return }
        currentPosition = position
        NSLayoutConstraint.deactivate(labelConstraints)
        labelConstraints = Self.constraints(for: position, label: label, container: self)
        NSLayoutConstraint.activate(labelConstraints)
    }

    /// The label's anchor constraints for a given badge position. The label is
    /// width-limited to most of the surface so long names truncate rather than
    /// overflow.
    private static func constraints(
        for position: BadgePosition,
        label: NSTextField,
        container: NSView
    ) -> [NSLayoutConstraint] {
        var constraints: [NSLayoutConstraint] = [
            label.widthAnchor.constraint(
                lessThanOrEqualTo: container.widthAnchor,
                constant: -(edgeInset * 2)
            )
        ]
        switch position {
        case .topLeading:
            constraints.append(label.topAnchor.constraint(equalTo: container.topAnchor, constant: edgeInset))
            constraints.append(label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: edgeInset))
        case .topTrailing:
            constraints.append(label.topAnchor.constraint(equalTo: container.topAnchor, constant: edgeInset))
            constraints.append(label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -edgeInset))
        case .bottomLeading:
            constraints.append(label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -edgeInset))
            constraints.append(label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: edgeInset))
        case .bottomTrailing:
            constraints.append(label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -edgeInset))
            constraints.append(label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -edgeInset))
        case .center:
            constraints.append(label.centerXAnchor.constraint(equalTo: container.centerXAnchor))
            constraints.append(label.centerYAnchor.constraint(equalTo: container.centerYAnchor))
        }
        return constraints
    }

    /// The text alignment that reads naturally for a given anchor.
    private static func alignment(for position: BadgePosition) -> NSTextAlignment {
        switch position {
        case .topLeading, .bottomLeading: return .left
        case .topTrailing, .bottomTrailing: return .right
        case .center: return .center
        }
    }
}
