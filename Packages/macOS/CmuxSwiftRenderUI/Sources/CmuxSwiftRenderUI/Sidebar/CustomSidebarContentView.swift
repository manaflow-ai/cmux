import AppKit
import CmuxFoundation
import CmuxSwiftRender

/// Pure native presentation of a loaded custom sidebar.
///
/// The in-process surface and the isolated render worker both use this view,
/// so file states, layout, actions, accessibility, and hit regions stay in
/// sync across the two render paths.
@MainActor
public final class CustomSidebarContentView: NSView {
    private let dispatch: SidebarActionDispatch
    private var contentInsets: CustomSidebarContentInsets
    private var mountedContent: NSView?

    /// Creates a sidebar presentation from value snapshots.
    public init(
        state: CustomSidebarModel.State,
        swiftRender: RenderNode?,
        hasRenderedSwift: Bool,
        dispatch: SidebarActionDispatch,
        contentInsets: CustomSidebarContentInsets
    ) {
        self.dispatch = dispatch
        self.contentInsets = contentInsets
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.group)
        update(
            state: state,
            swiftRender: swiftRender,
            hasRenderedSwift: hasRenderedSwift,
            contentInsets: contentInsets
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public var isFlipped: Bool {
        true
    }

    /// Replaces the mounted presentation with the latest renderer values.
    public func update(
        state: CustomSidebarModel.State,
        swiftRender: RenderNode?,
        hasRenderedSwift: Bool,
        contentInsets: CustomSidebarContentInsets
    ) {
        self.contentInsets = contentInsets
        let content = makeContent(
            state: state,
            swiftRender: swiftRender,
            hasRenderedSwift: hasRenderedSwift
        )
        replaceMountedContent(with: content)
    }

    /// Returns actionable descendants in this view's top-left coordinate space.
    /// The isolated render worker uses these regions to forward pointer events.
    public func tapTargets() -> [SidebarTapTarget] {
        layoutSubtreeIfNeeded()
        var targets: [SidebarTapTarget] = []

        func collect(_ view: NSView) {
            if let provider = view as? any SidebarTapTargetProviding,
               let action = provider.sidebarTapAction,
               !view.isHidden,
               view.alphaValue > 0
            {
                targets.append(SidebarTapTarget(frame: convert(view.bounds, from: view), action: action))
            }
            view.subviews.forEach(collect)
        }

        mountedContent.map(collect)
        return targets
    }

    private func makeContent(
        state: CustomSidebarModel.State,
        swiftRender: RenderNode?,
        hasRenderedSwift: Bool
    ) -> NSView {
        switch state {
        case .missing:
            let label = wrappingLabel(
                String(
                    localized: "sidebar.custom.missing",
                    defaultValue: "Sidebar file is empty or missing.",
                    bundle: .module
                )
            )
            label.font = GlobalFontMagnification.systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            return scrollWrap(label)
        case let .json(document):
            return scrollWrap(render(document.root))
        case .swiftSource:
            if let swiftRender {
                let rendered = RenderNodeView(
                    node: swiftRender,
                    dispatch: dispatch,
                    contentInsets: contentInsets
                )
                return swiftRender.kind == .hsplit ? rendered : scrollWrap(rendered)
            }
            if hasRenderedSwift {
                return scrollWrap(
                    errorView(
                        String(
                            localized: "sidebar.custom.noView",
                            defaultValue: "No supported sidebar view found.",
                            bundle: .module
                        )
                    )
                )
            }
            return scrollWrap(SidebarPlaceholderView())
        case let .failed(message):
            return scrollWrap(errorView(message))
        }
    }

    private func render(_ node: DSLNode) -> NSView {
        RenderNodeView(
            node: DSLSidebarRenderer.renderNode(node),
            dispatch: dispatch,
            contentInsets: contentInsets
        )
    }

    private func scrollWrap(_ content: NSView) -> NSView {
        let document = SidebarPaddedDocumentView(contentView: content)
        let scrollView = SidebarScrollContainer(documentView: document, axis: .vertical)
        scrollView.contentInsets = NSEdgeInsets(
            top: contentInsets.top,
            left: 0,
            bottom: contentInsets.bottom,
            right: 0
        )
        return scrollView
    }

    private func errorView(_ message: String) -> NSView {
        let icon = NSImageView(
            image: NSImage(
                systemSymbolName: "exclamationmark.triangle.fill",
                accessibilityDescription: nil
            ) ?? NSImage()
        )
        icon.contentTintColor = .systemOrange
        icon.setAccessibilityHidden(true)

        let title = NSTextField(
            labelWithString: String(
                localized: "sidebar.custom.error",
                defaultValue: "Sidebar error",
                bundle: .module
            )
        )
        title.font = GlobalFontMagnification.systemFont(ofSize: 11, weight: .bold)
        title.textColor = .systemOrange

        let heading = NSStackView(views: [icon, title])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 5

        let detail = wrappingLabel(message)
        detail.font = GlobalFontMagnification.systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [heading, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setAccessibilityElement(true)
        stack.setAccessibilityRole(.group)
        stack.setAccessibilityLabel(title.stringValue)
        stack.setAccessibilityHelp(message)
        return stack
    }

    private func wrappingLabel(_ value: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func replaceMountedContent(with content: NSView) {
        mountedContent?.removeFromSuperview()
        mountedContent = content
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        needsLayout = true
    }
}

@MainActor
private final class SidebarPaddedDocumentView: SidebarFlippedView {
    init(contentView: NSView) {
        super.init(frame: .zero)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            contentView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
private final class SidebarPlaceholderView: NSView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 1)
    }
}
