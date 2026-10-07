import AppKit

/// A CALayer-backed, horizontally scrolling strip of event thumbnails.
public final class AgentActivityThumbnailFilmstrip: NSView {
    private let scrollView = NSScrollView()
    private let stack = NSStackView()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.documentView = stack
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor), scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor), scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(events: [AgentActivityEvent], model: AgentActivityModel) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for event in events where event.displayFrame != nil {
            let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: 112, height: 66))
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.wantsLayer = true
            imageView.layer?.cornerRadius = 5
            imageView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            imageView.toolTip = AgentActivityFormat.time(event.time)
            imageView.widthAnchor.constraint(equalToConstant: 112).isActive = true
            imageView.heightAnchor.constraint(equalToConstant: 66).isActive = true
            stack.addArrangedSubview(imageView)
            if let frame = event.displayFrame {
                Task { @MainActor [weak imageView, model] in imageView?.image = await model.image(for: frame) }
            }
        }
    }
}
