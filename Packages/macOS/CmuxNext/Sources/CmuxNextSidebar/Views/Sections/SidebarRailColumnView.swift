public import AppKit
public import CmuxNextDesign
import Observation

/// The window rail (`window.rail`): the sidebar's sticky sections as one
/// column of icon buttons, drawn from the same layout document, item
/// infos and actions as the sidebar, which then shows only its workspace
/// list. The App places the column and supplies tooltips (title plus live
/// shortcut); everything else follows the sidebar model.
@MainActor
public final class SidebarRailColumnView: NSView {
    public let model: SidebarModel
    let rail = SidebarRailView()
    /// "Settings (⌘,)" for an item, or nil for its title alone.
    public var toolTipProvider: ((LayoutItemRef) -> String?)? {
        didSet { refresh() }
    }
    public var contextMenuProvider: ((SidebarContextTarget) -> NSMenu?)? {
        get { rail.contextMenuProvider }
        set { rail.contextMenuProvider = newValue }
    }
    /// Space above the first button: below the top row and the traffic
    /// lights. Set by the App.
    public var topInset: CGFloat = 0 {
        didSet { if oldValue != topInset { refresh() } }
    }
    private var observation: Task<Void, Never>?

    public init(model: SidebarModel) {
        self.model = model
        super.init(frame: .zero)
        rail.autoresizingMask = [.width, .height]
        rail.onActivate = { [weak model] id in model?.send(.activateItem(id)) }
        addSubview(rail)
        // task-owner: this view (cancelled in deinit); event-driven (Observation)
        observation = Task { [weak self, model] in
            for await _ in Observations({ (model.layout, model.itemInfo, model.activeProfileID, Metrics.sidebarRowHeight, Metrics.lineWidth(Metrics.dividerThickness)) }) {
                self?.refresh()
            }
        }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        observation?.cancel()
    }

    override public var isFlipped: Bool { true }

    override public func layout() {
        super.layout()
        rail.frame = bounds
    }

    /// Sizes from the design tokens, read at layout time so density and
    /// `appearance.borders` apply live.
    public static func metrics(width: CGFloat, topInset: CGFloat) -> SidebarRailMetrics {
        SidebarRailMetrics(width: width, buttonSize: Metrics.sidebarRowHeight + Metrics.space2, buttonGap: Metrics.space1,
                           sectionGap: Metrics.space2, lineWidth: Metrics.lineWidth(Metrics.dividerThickness),
                           lineInset: Metrics.space3, topInset: topInset, bottomInset: Metrics.space3)
    }

    func refresh() {
        let hidden = Set(model.itemInfo.filter(\.value.isHidden).keys)
        var document = model.layout
        document.sections = document.sections.hidingItems(hidden)
        var toolTips: [LayoutItemID: String] = [:]
        if let toolTipProvider {
            for section in document.sections {
                for item in section.items {
                    if let tip = toolTipProvider(item.ref) { toolTips[item.id] = tip }
                }
            }
        }
        rail.update(SidebarRailView.Content(document: document, room: model.activeProfileID?.rawValue, infos: model.itemInfo,
                                            toolTips: toolTips, metrics: Self.metrics(width: bounds.width, topInset: topInset)))
    }

    override public func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { refresh() }
    }

    /// The button view for `id` (tests).
    public func itemView(_ id: LayoutItemID) -> NSView? { rail.itemView(id) }
    /// The current layout (tests).
    public var layoutResult: SidebarRailLayout { rail.layoutResult }
}
