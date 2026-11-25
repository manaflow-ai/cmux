public import AppKit
public import CmuxNextDesign
import SwiftUI

/// The Automations page's AppKit view: a container around the SwiftUI page. `ThemeScope` tells the
/// views it draws about a theme change through `viewDidChangeEffectiveAppearance` (it is not
/// observable), so this view reads its window's tokens again there and redraws the page in them.
@MainActor
public final class AutomationsHostingView: NSView {
    /// The colors the page draws in now.
    public private(set) var palette: AutomationsPalette
    private let model: AutomationsPage
    private let tokens: @MainActor () -> ThemeTokens
    private let actions: AutomationsPageView.Actions
    private let hosting: NSHostingView<AnyView>

    init(model: AutomationsPage, tokens: @escaping @MainActor () -> ThemeTokens, actions: AutomationsPageView.Actions = .init()) {
        self.model = model
        self.tokens = tokens
        self.actions = actions
        let palette = AutomationsPalette(tokens: tokens())
        self.palette = palette
        hosting = NSHostingView(rootView: Self.page(model, palette, actions))
        super.init(frame: .zero)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor), hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor), hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let next = AutomationsPalette(tokens: tokens())
        guard next != palette else { return }
        palette = next
        hosting.rootView = Self.page(model, next, actions)
    }

    private static func page(_ model: AutomationsPage, _ palette: AutomationsPalette, _ actions: AutomationsPageView.Actions) -> AnyView {
        AnyView(AutomationsPageView(page: model, palette: palette, actions: actions).task { await model.reload(now: .now) })
    }
}
