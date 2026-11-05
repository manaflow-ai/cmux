public import AppKit
public import CmuxNextDesign

/// The Automations page's AppKit view: a container around ``AutomationsPageView``. `ThemeScope`
/// tells the views it draws about a theme change through `viewDidChangeEffectiveAppearance` (it is
/// not observable), so this view reads its window's tokens again there and redraws the page in them.
/// Each time it joins a window it loads both sources again, as the page appears.
@MainActor
public final class AutomationsHostingView: NSView {
    /// The colors the page draws in now.
    public private(set) var palette: AutomationsPalette
    private let model: AutomationsPage
    private let tokens: @MainActor () -> ThemeTokens
    /// The page.
    let page: AutomationsPageView
    // task-owner: the view's `loading`, started when it joins a window and cancelled when it leaves.
    private var loading: Task<Void, Never>?

    init(model: AutomationsPage, tokens: @escaping @MainActor () -> ThemeTokens, actions: AutomationsPageView.Actions = .init()) {
        self.model = model
        self.tokens = tokens
        let palette = AutomationsPalette(tokens: tokens())
        self.palette = palette
        page = AutomationsPageView(page: model, palette: palette, actions: actions)
        super.init(frame: .zero)
        page.translatesAutoresizingMaskIntoConstraints = false
        addSubview(page)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: leadingAnchor), page.trailingAnchor.constraint(equalTo: trailingAnchor),
            page.topAnchor.constraint(equalTo: topAnchor), page.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        loading?.cancel()
        loading = nil
        guard window != nil else { return }
        let model = model
        loading = Task { await model.reload(now: .now) }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let next = AutomationsPalette(tokens: tokens())
        guard next != palette else { return }
        palette = next
        page.palette = next
    }
}
