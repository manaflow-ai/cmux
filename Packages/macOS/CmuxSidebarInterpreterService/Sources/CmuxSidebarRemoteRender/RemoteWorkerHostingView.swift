import AppKit
import CmuxSwiftRenderUI

/// Native root for the worker's never-ordered rendering window.
///
/// It exposes layout and display invalidations to the explicit display pump,
/// and collects the current renderer's geometric action targets after layout.
@MainActor
final class RemoteWorkerHostingView: NSView {
    var onInvalidation: (@MainActor () -> Void)?
    private var sidebarContent: CustomSidebarContentView

    init(contentView: CustomSidebarContentView) {
        sidebarContent = contentView
        super.init(frame: .zero)
        wantsLayer = true
        install(contentView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool {
        true
    }

    override var needsLayout: Bool {
        didSet {
            if needsLayout {
                onInvalidation?()
            }
        }
    }

    override var needsDisplay: Bool {
        didSet {
            if needsDisplay {
                onInvalidation?()
            }
        }
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(invalidRect)
        onInvalidation?()
    }

    func replaceContent(with contentView: CustomSidebarContentView) {
        sidebarContent.removeFromSuperview()
        sidebarContent = contentView
        install(contentView)
        needsLayout = true
        needsDisplay = true
    }

    func tapTargets() -> [SidebarTapTarget] {
        sidebarContent.tapTargets()
    }

    private func install(_ contentView: CustomSidebarContentView) {
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}
