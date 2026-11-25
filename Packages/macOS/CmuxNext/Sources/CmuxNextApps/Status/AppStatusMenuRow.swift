public import AppKit
import CmuxNextDesign

/// One extension status item as a row of the menu bar item's menu: its drawn scene inset as a menu
/// row's title is, at the menu's width, its height the scene's. A row whose scene has not drawn yet
/// is zero high (``AppStatusItems/menuBarRows()`` leaves it out).
@MainActor
final class AppStatusMenuRow: NSView {
    /// A menu row's content inset from both edges: the menu grid's, where AppKit starts a row's
    /// content and its separators (``MenuMetrics/separatorInset``).
    static let inset = MenuMetrics.separatorInset
    /// The width the row asks for.
    static let width: CGFloat = 280
    /// The room above and below the scene.
    static let verticalSpace: CGFloat = 4

    private let scene: AppSceneHostingView

    init(scene: AppSceneHostingView) {
        self.scene = scene
        super.init(frame: .zero)
        addSubview(scene)
        let height = scene.preferredHeight(width: Self.width - 2 * Self.inset)
        frame = CGRect(x: 0, y: 0, width: Self.width, height: height > 0 ? height + 2 * Self.verticalSpace : 0)
        autoresizingMask = [.width]
        scene.onContentSizeChange = { [weak self] in self?.needsLayout = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let width = max(0, bounds.width - 2 * Self.inset)
        scene.frame = CGRect(x: Self.inset, y: Self.verticalSpace, width: width, height: scene.preferredHeight(width: width))
    }
}
