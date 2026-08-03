import AppKit
import CmuxFoundation
@_spi(CmuxHostTransport) import CmuxExtensionKit

@MainActor
final class CMUXSidebarPresentationView: NSView {
    private var presentation: CmuxSidebarPresentation?
    private var onAction: ((String) -> Void)?
    private var renderedView: NSView?
    private var fontObserver: GlobalFontMagnificationChangeObserver?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        fontObserver = GlobalFontMagnificationChangeObserver { [weak self] in
            self?.render()
        }
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        presentation: CmuxSidebarPresentation?,
        onAction: @escaping (String) -> Void
    ) {
        self.presentation = presentation
        self.onAction = onAction
        render()
    }

    func showLoading() {
        guard presentation == nil else { return }
        install(renderNode(.progress))
    }

    func showError(_ message: String) {
        install(
            renderNode(
                .inset(
                    .all(12),
                    .text(
                        message,
                        style: .init(size: 11, color: .error, maximumLineCount: nil)
                    )
                )
            )
        )
    }

    private func render() {
        guard let presentation else {
            showLoading()
            return
        }
        install(renderNode(presentation.root))
    }

    private func install(_ content: NSView) {
        renderedView?.removeFromSuperview()
        renderedView = content
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func renderNode(_ node: CmuxSidebarPresentationNode) -> NSView {
        switch node {
        case .text(let value, let style):
            let field = NSTextField(wrappingLabelWithString: value)
            field.font = GlobalFontMagnification.systemFont(
                ofSize: style.size,
                weight: fontWeight(style.weight)
            )
            field.textColor = color(style.color)
            field.maximumNumberOfLines = style.maximumLineCount ?? 0
            field.lineBreakMode = style.maximumLineCount == 1 ? .byTruncatingTail : .byWordWrapping
            return field
        case .symbol(let name, let presentationColor):
            let imageView = NSImageView(
                image: NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
            )
            imageView.contentTintColor = color(presentationColor)
            return imageView
        case .button(let button):
            let control = CMUXSidebarPresentationButtonView(
                title: button.title,
                actionID: button.id,
                onAction: { [weak self] actionID in self?.onAction?(actionID) }
            )
            control.isEnabled = button.isEnabled
            control.toolTip = button.help
            if let systemImageName = button.systemImageName {
                control.image = NSImage(systemSymbolName: systemImageName, accessibilityDescription: nil)
                control.imagePosition = .imageLeading
            }
            return control
        case .stack(let axis, let spacing, let children):
            if axis == .depth {
                let container = NSView()
                for child in children {
                    let childView = renderNode(child)
                    childView.translatesAutoresizingMaskIntoConstraints = false
                    container.addSubview(childView)
                    NSLayoutConstraint.activate([
                        childView.topAnchor.constraint(equalTo: container.topAnchor),
                        childView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                        childView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                        childView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                    ])
                }
                return container
            }
            let stack = NSStackView(views: children.map(renderNode))
            stack.orientation = axis == .horizontal ? .horizontal : .vertical
            stack.alignment = axis == .horizontal ? .centerY : .leading
            stack.spacing = spacing
            if axis == .vertical {
                stack.arrangedSubviews.forEach {
                    $0.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
                }
            }
            return stack
        case .scroll(let child):
            return CMUXSidebarPresentationScrollView(documentView: renderNode(child))
        case .spacer(let minimumLength):
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
            if minimumLength > 0 {
                spacer.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumLength).isActive = true
            }
            return spacer
        case .divider:
            let divider = NSBox()
            divider.boxType = .separator
            divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
            return divider
        case .progress:
            let progress = NSProgressIndicator()
            progress.style = .spinning
            progress.controlSize = .small
            progress.startAnimation(nil)
            return progress
        case .inset(let insets, let child):
            let container = NSView()
            let childView = renderNode(child)
            childView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(childView)
            NSLayoutConstraint.activate([
                childView.topAnchor.constraint(equalTo: container.topAnchor, constant: insets.top),
                childView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: insets.leading),
                childView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -insets.trailing),
                childView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -insets.bottom),
            ])
            return container
        case .panel(let child):
            let container = NSView()
            container.wantsLayer = true
            container.layer?.cornerRadius = 6
            container.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.9).cgColor
            let childView = renderNode(child)
            childView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(childView)
            NSLayoutConstraint.activate([
                childView.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
                childView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
                childView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
                childView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            ])
            return container
        case .empty:
            return NSView()
        }
    }

    private func fontWeight(_ weight: CmuxSidebarPresentationFontWeight) -> NSFont.Weight {
        switch weight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        }
    }

    private func color(_ presentationColor: CmuxSidebarPresentationColor) -> NSColor {
        switch presentationColor {
        case .primary: .labelColor
        case .secondary: .secondaryLabelColor
        case .accent: .controlAccentColor
        case .error: .systemRed
        }
    }
}

@MainActor
private final class CMUXSidebarPresentationButtonView: NSButton {
    private let actionID: String
    private let actionHandler: (String) -> Void

    init(title: String, actionID: String, onAction: @escaping (String) -> Void) {
        self.actionID = actionID
        actionHandler = onAction
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        target = self
        action = #selector(performAction(_:))
        setAccessibilityIdentifier("CMUXExtensionAction.\(actionID)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc
    private func performAction(_ sender: Any?) {
        actionHandler(actionID)
    }
}

@MainActor
private final class CMUXSidebarPresentationScrollView: NSScrollView {
    private let content: NSView

    init(documentView: NSView) {
        content = documentView
        super.init(frame: .zero)
        borderType = .noBorder
        drawsBackground = false
        hasHorizontalScroller = false
        hasVerticalScroller = true
        autohidesScrollers = true
        self.documentView = documentView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let width = max(contentSize.width, 1)
        content.setFrameSize(NSSize(width: width, height: content.frame.height))
        content.layoutSubtreeIfNeeded()
        content.setFrameSize(NSSize(width: width, height: max(content.fittingSize.height, contentSize.height)))
    }
}
