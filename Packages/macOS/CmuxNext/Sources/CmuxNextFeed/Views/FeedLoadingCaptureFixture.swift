#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit
import CmuxNextDesign

/// DEBUG ONLY, for captures of the Feed's loading states (ui-state-fixes M4): a real ``FeedModel``
/// whose owner has not sent its first snapshot and whose reports mailbox was not read, so the real
/// views show "Loading…" and "Loading reports…". Compiled out of Release.
extension FeedModel {
    /// A started model over an owner that never answers: `loaded` and `reportsLoaded` stay false.
    public static func captureUnread() -> FeedModel {
        let model = FeedModel(source: SilentFeedSource())
        model.start()
        return model
    }

    /// The Inbox's reports basket (``ReportsBasketView``) over this model, in its window's theme.
    public func captureReportsBasket() -> NSView {
        ReportsBasketCaptureHost(model: self)
    }
}

/// A feed owner that is still connecting: it never sends a snapshot.
@MainActor
private final class SilentFeedSource: FeedSource {
    func start(_ sink: @escaping @MainActor (FeedSourceEvent) -> Void) {}
    func send(_ intent: FeedIntent) {}
    func stop() {}
}

/// The reports basket with the page colors ``FeedHostView`` resolves for it.
private final class ReportsBasketCaptureHost: NSView {
    private let basket: ReportsBasketView

    init(model: FeedModel) {
        basket = ReportsBasketView(model: model, onReply: nil)
        super.init(frame: .zero)
        wantsLayer = true
        embed(basket)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    nonisolated override var wantsUpdateLayer: Bool { true }

    override func updateLayer() { resolveColors() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolveColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveColors()
    }

    private func resolveColors() {
        let colors = performWithTheme {
            FeedColors.resolved(background: Palette.surfaceOverride(.internalPage) ?? Palette.paneFill).basket
        }
        layer?.backgroundColor = colors.background.cgColor
        basket.apply(colors)
    }
}
#endif
