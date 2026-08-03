#if DEBUG
import AppKit

@MainActor
final class OverlayComparison: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor

        let title = NSTextField(labelWithString: "OVERLAY · native (grey) + GPU spokes (red)")
        title.font = .systemFont(ofSize: 11, weight: .heavy)

        let superimposed = comparisonWell(label: "superimposed (≈32pt)") {
            let container = NSView()
            let native = NativeSpinner(threaded: false, controlSize: .regular)
            let gpu = GPUSpinnerNSView(frame: .zero)
            gpu.style = .macOSSpokes
            gpu.color = NSColor.systemRed.withAlphaComponent(0.7)
            for child in [native, gpu] {
                child.frame = NSRect(x: 0, y: 0, width: 32, height: 32)
                child.autoresizingMask = [.width, .height]
                container.addSubview(child)
            }
            return container
        }
        let native = comparisonWell(label: "native only") {
            NativeSpinner(threaded: false, controlSize: .regular)
        }
        let gpu = comparisonWell(label: "GPU only (32pt)") {
            let view = GPUSpinnerNSView(frame: .zero)
            view.style = .macOSSpokes
            view.color = .secondaryLabelColor
            return view
        }
        let row = NSStackView(views: [superimposed, native, gpu])
        row.orientation = .horizontal
        row.spacing = 20
        let stack = NSStackView(views: [title, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func comparisonWell(label: String, content: () -> NSView) -> NSView {
        let well = NSView()
        well.wantsLayer = true
        well.layer?.cornerRadius = 8
        well.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        let child = content()
        child.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(child)
        NSLayoutConstraint.activate([
            well.widthAnchor.constraint(equalToConstant: 88),
            well.heightAnchor.constraint(equalToConstant: 88),
            child.centerXAnchor.constraint(equalTo: well.centerXAnchor),
            child.centerYAnchor.constraint(equalTo: well.centerYAnchor),
            child.widthAnchor.constraint(equalToConstant: 32),
            child.heightAnchor.constraint(equalToConstant: 32),
        ])
        let caption = NSTextField(labelWithString: label)
        caption.font = .systemFont(ofSize: 10)
        caption.textColor = .secondaryLabelColor
        caption.alignment = .center
        let stack = NSStackView(views: [well, caption])
        stack.orientation = .vertical
        stack.spacing = 4
        return stack
    }
}
#endif
