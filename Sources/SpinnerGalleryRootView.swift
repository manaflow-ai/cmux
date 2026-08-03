#if DEBUG
import AppKit

@MainActor
final class SpinnerGalleryRootView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let header = NSTextField(labelWithString: "Indeterminate spinners · energy characteristics")
        header.font = .systemFont(ofSize: 12, weight: .semibold)
        header.textColor = .secondaryLabelColor

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        content.addArrangedSubview(OverlayComparison())
        for spec in Self.specs {
            content.addArrangedSubview(SpinnerCard(spec: spec))
        }
        let footnote = NSTextField(wrappingLabelWithString: "Ratings are mechanism-based (GPU transform vs CPU per-frame redraw, main-thread vs off-thread), not live measurements. Confirm with Activity Monitor → Energy or Instruments → Energy Log while this window is frontmost.")
        footnote.font = .systemFont(ofSize: 10)
        footnote.textColor = .secondaryLabelColor
        content.addArrangedSubview(footnote)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = content
        for child in [header, scroll] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.arrangedSubviews[0].widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28),
        ])
        for view in content.arrangedSubviews.dropFirst() {
            view.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28).isActive = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static var specs: [SpinnerSpec] {
        let tint = NSColor.secondaryLabelColor
        return [
            SpinnerSpec(title: "GPU spokes (shipping)", mechanism: "Core Animation transform.rotation.z, discrete steps. Render server animation with no main-thread work per frame.", energy: .low, shipping: true) {
                let view = GPUSpinnerNSView(frame: .zero); view.style = .macOSSpokes; view.color = tint; return view
            },
            SpinnerSpec(title: "GPU arc (legacy cmux)", mechanism: "Core Animation continuous rotation, composited by the render server.", energy: .low, shipping: false) {
                let view = GPUSpinnerNSView(frame: .zero); view.style = .arc; view.color = tint; return view
            },
            SpinnerSpec(title: "NSProgressIndicator (default)", mechanism: "AppKit system spinner using main-thread redraws.", energy: .high, shipping: false) {
                NativeSpinner(threaded: false)
            },
            SpinnerSpec(title: "NSProgressIndicator (threaded)", mechanism: "AppKit system spinner with threaded animation.", energy: .mediumHigh, shipping: false) {
                NativeSpinner(threaded: true)
            },
        ]
    }
}
#endif
