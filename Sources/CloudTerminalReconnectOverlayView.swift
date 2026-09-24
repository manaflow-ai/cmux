import AppKit
import SwiftUI

/// A native, pane-owned host. Connection state and creation failures share the
/// same responsive card, so a narrow terminal never gets a 260pt minimum dialog.
@MainActor
final class CloudTerminalReconnectOverlayView: NSView {
    /// Identifies the card host inside the overlay. The card itself is SwiftUI,
    /// so its AppKit class is an implementation detail; this identifier is the
    /// stable handle for locating the laid-out card.
    static let cardAccessibilityIdentifier = "CloudTerminalReconnectCard"

    var onReconnect: (() -> Void)?
    var onDismiss: (() -> Void)?
    private(set) var currentPresentation: CloudTerminalReconnectOverlayPolicy.Presentation?
    /// The action wired to the card's Retry control, or nil when the current
    /// presentation offers no retry. This is the value handed to the card, so
    /// it is the same path the control invokes.
    private(set) var reconnectAction: (() -> Void)?
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private var renderedWidth: CGFloat = 0
    private var needsContentUpdate = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
        hostingView.sizingOptions = [.intrinsicContentSize]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.setAccessibilityIdentifier(Self.cardAccessibilityIdentifier)
        addSubview(hostingView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func layout() {
        super.layout()
        guard let presentation = currentPresentation else { return }
        let width = max(1, min(360, bounds.width - 24))
        if needsContentUpdate || renderedWidth != width {
            renderedWidth = width
            needsContentUpdate = false
            hostingView.rootView = AnyView(
                Content(
                    presentation: presentation,
                    onReconnect: reconnectAction,
                    onDismiss: { [weak self] in self?.onDismiss?() }
                )
                .frame(width: width)
                .fixedSize(horizontal: false, vertical: true)
            )
        }
        let height = ceil(hostingView.fittingSize.height)
        let frame = NSRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
        if hostingView.frame != frame { hostingView.frame = frame }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0 else { return nil }
        let localPoint = convert(point, from: superview)
        guard hostingView.frame.contains(localPoint) else { return nil }
        return hostingView.hitTest(localPoint) ?? self
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        currentPresentation.map { CloudErrorCopy.menu($0.copyableError) }
    }

    func apply(_ presentation: CloudTerminalReconnectOverlayPolicy.Presentation) {
        guard currentPresentation != presentation else { return }
        currentPresentation = presentation
        reconnectAction = presentation.showsReconnectButton
            ? { [weak self] in self?.onReconnect?() }
            : nil
        needsContentUpdate = true
        needsLayout = true
    }

    private struct Content: View {
        let presentation: CloudTerminalReconnectOverlayPolicy.Presentation
        let onReconnect: (() -> Void)?
        let onDismiss: () -> Void
        #if DEBUG
        @AppStorage("cloudPaneFailurePrototypeStyle") private var prototypeStyle = "compact-bordered"
        #endif

        private var style: CloudFailureCard.Style {
            #if DEBUG
            CloudFailureCard.Style(rawValue: prototypeStyle) ?? .compactBordered
            #else
            .compactBordered
            #endif
        }

        var body: some View {
            VStack(spacing: 10) {
                if presentation.showsProgress { ProgressView().controlSize(.small) }
                CloudFailureCard(
                    title: presentation.title,
                    detail: presentation.detail,
                    copyableText: presentation.copyableError,
                    style: style,
                    onRetry: onReconnect,
                    onDismiss: onDismiss
                )
            }
        }
    }
}
