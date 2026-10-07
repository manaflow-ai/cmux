import AppKit
import CmuxNextDesign

/// Small layout helpers for the Import and Theme variants: a top-anchored
/// column, a hairline, a caption header and a vertical scroller.
@MainActor
enum VariantLayout {
    /// A container whose views stack from the top (or the bottom); views in
    /// `fill` take the full width, the rest keep their natural width.
    static func column(_ views: [NSView], spacing: CGFloat, fill: [NSView] = [], alignment: NSLayoutConstraint.Attribute = .leading,
                       anchoredToBottom: Bool = false) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = alignment
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        var constraints = [
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ]
        if anchoredToBottom {
            constraints += [stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                            stack.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor)]
        } else {
            constraints += [stack.topAnchor.constraint(equalTo: container.topAnchor),
                            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor)]
        }
        constraints += fill.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) }
        NSLayoutConstraint.activate(constraints)
        return container
    }

    /// A 1 pt separator line in the theme's separator color.
    static func hairline(vertical: Bool = false) -> NSView {
        let line = ThemedView()
        line.fill = { Palette.separator }
        let size = vertical ? line.widthAnchor : line.heightAnchor
        size.constraint(equalToConstant: 1).isActive = true
        return line
    }

    /// A small section header ("Browsers", "Dark").
    static func header(_ text: String) -> NSTextField {
        OnboardingLabel.make(text, font: .systemFont(ofSize: 11, weight: .semibold), color: Palette.textTertiary)
    }

    /// A transparent vertical scroller around `content`; its height follows
    /// the content until the space around it caps it.
    static func scroller(_ content: NSView) -> NSScrollView {
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        let scroll = NSScrollView()
        scroll.contentView = TopAnchoredClipView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        SystemScrollers.follow(scroll)
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let fit = scroll.heightAnchor.constraint(equalTo: document.heightAnchor)
        // Below NSWindow's stay-put priority (500): a long list scrolls instead of growing the window.
        fit.priority = .init(480)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            fit,
        ])
        return scroll
    }

    /// A container whose content reaches `outset` past its edges: ringed
    /// tiles keep a ring inset, so this lines the tiles up with the margin.
    static func outset(_ content: NSView, by outset: CGFloat = 4) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: -outset),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: outset),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }
}

/// A clip view that keeps a short document at the top (AppKit's default
/// clip view is unflipped and parks it at the bottom).
final class TopAnchoredClipView: NSClipView {
    override var isFlipped: Bool { true }
}
