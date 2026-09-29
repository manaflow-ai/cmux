public import AppKit
import CmuxNextDesign
import Observation

/// Glass sidebar panel that owns its width.
///
/// Pin leading, top, and bottom; the view animates its own width constraint
/// for `SidebarModel.presentation` (expanded, icons only, hidden) and for
/// live resizing through the trailing handle. Neighbors should attach to its
/// trailing anchor so they follow.
public final class SidebarContainerView: NSView {
    public let sidebarView: SidebarView
    public let model: SidebarModel
    /// The width constraint this view drives. Do not add another.
    public private(set) var widthConstraint: NSLayoutConstraint!

    private let panel: NSGlassEffectView
    private let handle: SidebarResizeHandle
    private var observation: Task<Void, Never>?

    /// Dragging narrower than this switches to icons-only; dragging an
    /// icons-only sidebar wider than this expands it.
    public static let collapseThreshold: CGFloat = 130

    public init(model: SidebarModel) {
        self.model = model
        sidebarView = SidebarView(model: model)
        panel = Glass.makePanel(content: sidebarView)
        handle = SidebarResizeHandle()
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)
        addSubview(handle)
        handle.translatesAutoresizingMaskIntoConstraints = false
        widthConstraint = widthAnchor.constraint(equalToConstant: model.displayWidth)
        NSLayoutConstraint.activate([
            widthConstraint,
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            handle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 4),
            handle.topAnchor.constraint(equalTo: topAnchor),
            handle.bottomAnchor.constraint(equalTo: bottomAnchor),
            handle.widthAnchor.constraint(equalToConstant: 8),
        ])
        panel.alphaValue = model.presentation == .hidden ? 0 : 1
        handle.onDrag = { [weak self] phase in self?.handleDrag(phase) }
        observe()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        observation?.cancel()
    }

    private var liveStartWidth: CGFloat = 0

    private func handleDrag(_ phase: SidebarResizeHandle.Phase) {
        switch phase {
        case .began:
            liveStartWidth = model.displayWidth
        case let .changed(dx):
            let proposed = liveStartWidth + dx
            switch model.presentation {
            case .expanded:
                if proposed < Self.collapseThreshold {
                    model.presentation = .iconsOnly
                } else {
                    model.width = proposed
                    widthConstraint.constant = model.width
                }
            case .iconsOnly:
                if proposed > Self.collapseThreshold {
                    model.width = max(proposed, SidebarModel.widthRange.lowerBound)
                    model.presentation = .expanded
                }
            case .hidden:
                break
            }
        case .ended:
            break
        case .doubleClick:
            model.togglePresentation()
        }
    }

    private func observe() {
        let model = model
        observation = Task { [weak self] in
            for await (presentation, width) in Observations({ (model.presentation, model.width) }) {
                self?.apply(presentation: presentation, width: width)
            }
        }
    }

    private func apply(presentation: SidebarPresentation, width: CGFloat) {
        let target = model.displayWidth
        handle.isHidden = presentation == .hidden
        guard widthConstraint.constant != target else { return }
        if handle.isDragging, presentation == .expanded, widthConstraint.constant > Self.collapseThreshold {
            widthConstraint.constant = target
            return
        }
        let alpha: CGFloat = presentation == .hidden ? 0 : 1
        Motion.animate(Motion.width) {
            widthConstraint.animator().constant = target
            panel.animator().alphaValue = alpha
            superview?.layoutSubtreeIfNeeded()
        }
    }
}

/// Invisible strip on the sidebar's trailing edge that resizes it.
final class SidebarResizeHandle: NSView {
    enum Phase {
        case began
        case changed(CGFloat)
        case ended
        case doubleClick
    }

    var onDrag: ((Phase) -> Void)?
    private(set) var isDragging = false
    private var startX: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel(Strings.resize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .columnResize)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDrag?(.doubleClick)
            return
        }
        isDragging = true
        startX = event.locationInWindow.x
        onDrag?(.began)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        onDrag?(.changed(event.locationInWindow.x - startX))
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        onDrag?(.ended)
    }
}
