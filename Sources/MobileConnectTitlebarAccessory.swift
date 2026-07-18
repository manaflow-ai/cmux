import AppKit
import SwiftUI

/// Right-side titlebar accessory hosting the iPhone button that opens the
/// Mobile Connect (phone pairing) window. Installed per main terminal
/// window by `UpdateTitlebarAccessoryController` alongside the left-side
/// controls accessory; visibility in minimal mode and fullscreen is managed
/// there. The button itself is gated on
/// ``CmuxFeatureFlags/isMobileConnectButtonEnabled`` inside the SwiftUI
/// view, so a PostHog toggle applies live without re-attaching accessories.
final class MobileConnectTitlebarAccessoryViewController: NSTitlebarAccessoryViewController {
    private let hostingView: NSHostingView<TitlebarTrailingControls>
    private var sizeUpdatePending = false

    init() {
        let hostingView = NSHostingView(rootView: TitlebarTrailingControls())
        self.hostingView = hostingView
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .right
        hostingView.sizingOptions = [.intrinsicContentSize]
        hostingView.setContentHuggingPriority(.required, for: .horizontal)
        view = hostingView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        scheduleSizeUpdate()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        scheduleSizeUpdate()
    }

    private func scheduleSizeUpdate() {
        guard !sizeUpdatePending else { return }
        sizeUpdatePending = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            sizeUpdatePending = false
            updatePreferredSize()
        }
    }

    private func updatePreferredSize() {
        hostingView.invalidateIntrinsicContentSize()
        hostingView.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize
        guard fittingSize.width > 0, fittingSize.height > 0 else { return }

        let size = NSSize(
            width: ceil(fittingSize.width),
            height: max(28, ceil(fittingSize.height))
        )
        guard preferredContentSize != size || hostingView.frame.size != size else { return }
        preferredContentSize = size
        hostingView.setFrameSize(size)
    }
}

/// Trailing titlebar cluster. Mobile Connect now lives in the sidebar footer.
private struct TitlebarTrailingControls: View {
    var body: some View {
        HStack(spacing: 0) {
            ProBadgeView()
        }
        // The accessory controller sizes its AppKit slot from this root view.
        // Without a fixed horizontal size, the conditional Pro badge can first
        // report an empty width and later render its capsule outside the slot,
        // leaving only a clipped circular rim at the window's trailing edge.
        .fixedSize(horizontal: true, vertical: false)
        .padding(.trailing, 8)
    }
}
