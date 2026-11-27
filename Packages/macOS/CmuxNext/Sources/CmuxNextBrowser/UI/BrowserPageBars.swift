import AppKit
import CmuxNextDesign

/// The find pill and the prompt bar over a browser pane's page (`BrowserChromeView`), each made the
/// first time it shows, as Chrome makes its find bar and infobars only when one is needed. A new
/// pane's first frame shows neither: building both was about a third of Shift-Cmd-L's key turn
/// (25-40 ms on an efficiency core, #32909).
///
/// Each bar sits at the page's edge by the toolbar (`ToolbarEdgeConstraints`): the find pill at the
/// trailing corner, the prompt bar centered. The find pill draws above the prompt bar.
@MainActor
final class BrowserPageBars {
    private(set) var findBarIfMade: FindBarView?
    private(set) var promptBarIfMade: PromptBarView?
    /// The find pill's close button and Escape.
    var onCloseFind: (() -> Void)?

    private weak var parent: NSView?
    private weak var page: NSView?
    private let edge: ToolbarEdgeConstraints
    private let density: DensityBinding
    private let position: () -> ToolbarPosition

    /// - Parameters:
    ///   - parent: The chrome view the bars are added to.
    ///   - page: The page area they sit over.
    ///   - edge: The chrome's top and bottom constraint sets, which take each bar's edge constraint.
    ///   - density: The chrome's token binding, which keeps the bars' insets live.
    ///   - position: The toolbar's edge now.
    init(parent: NSView, page: NSView, edge: ToolbarEdgeConstraints, density: DensityBinding, position: @escaping () -> ToolbarPosition) {
        self.parent = parent
        self.page = page
        self.edge = edge
        self.density = density
        self.position = position
    }

    /// The bars made so far that show now, with their glass (the page's occlusion holes).
    var shown: [(bar: NSView, glass: OverlaySurfaceView?)] {
        let find = findBarIfMade.map { (bar: $0 as NSView, glass: $0.glass) }
        let prompt = promptBarIfMade.map { (bar: $0 as NSView, glass: $0.glass) }
        return [find, prompt].compactMap { $0 }.filter { !$0.bar.isHidden && $0.bar.superview != nil }
    }

    /// The find pill, made hidden at the page's trailing corner on first use.
    var findBar: FindBarView {
        if let findBarIfMade { return findBarIfMade }
        let bar = FindBarView()
        bar.isHidden = true
        bar.onClose = { [weak self] in self?.onCloseFind?() }
        findBarIfMade = bar
        guard let parent, let page else { return bar }
        parent.addSubview(bar)
        install(top: bar.topAnchor.constraint(equalTo: page.topAnchor, constant: FindPillMetrics.inset),
                bottom: bar.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -FindPillMetrics.inset))
        NSLayoutConstraint.activate([
            bar.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -FindPillMetrics.inset),
            bar.leadingAnchor.constraint(greaterThanOrEqualTo: page.leadingAnchor, constant: FindPillMetrics.inset),
        ])
        return bar
    }

    /// The find pill, made on first use, finding in `tab`.
    func findBar(on tab: any BrowserTab) -> FindBarView {
        let bar = findBar
        bar.tab = tab
        return bar
    }

    /// The prompt bar, made hidden and centered at the page's edge on first use.
    var promptBar: PromptBarView {
        if let promptBarIfMade { return promptBarIfMade }
        let bar = PromptBarView()
        bar.isHidden = true
        promptBarIfMade = bar
        guard let parent, let page else { return bar }
        // Under the find pill when it exists (a nil relative view would put it under the page).
        if let find = findBarIfMade { parent.addSubview(bar, positioned: .below, relativeTo: find) } else { parent.addSubview(bar) }
        install(top: density.bind(bar.topAnchor.constraint(equalTo: page.topAnchor)) { BrowserMetrics.overlayInset },
                bottom: density.bind(bar.bottomAnchor.constraint(equalTo: page.bottomAnchor)) { -BrowserMetrics.overlayInset })
        NSLayoutConstraint.activate([
            bar.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            density.bind(bar.leadingAnchor.constraint(greaterThanOrEqualTo: page.leadingAnchor)) { BrowserMetrics.overlayInset },
        ])
        // Observe again so the tokens these new bindings read are tracked too (a live inset change reaches the bar).
        density.start()
        return bar
    }

    /// Adds a bar's edge constraints to the chrome's sets and activates the one for the toolbar's edge now.
    private func install(top: NSLayoutConstraint, bottom: NSLayoutConstraint) {
        edge.top.append(top)
        edge.bottom.append(bottom)
        (position() == .top ? top : bottom).isActive = true
    }
}
