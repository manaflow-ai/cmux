#if DEBUG
import AppKit

/// A scroll view that mirrors its zoom and scroll position onto ``partner`` (the variant's other side).
@MainActor
final class HomeCompareSyncedScroll: NSScrollView {
    weak var partner: HomeCompareSyncedScroll?
    private var mirroring = false

    override var magnification: CGFloat {
        didSet { mirror() }
    }

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        mirror()
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        mirror()
    }

    private func mirror() {
        guard !mirroring, let partner, !partner.mirroring else { return }
        mirroring = true
        defer { mirroring = false }
        partner.magnification = magnification
        partner.contentView.scroll(to: contentView.bounds.origin)
        partner.reflectScrolledClipView(partner.contentView)
    }
}
#endif
