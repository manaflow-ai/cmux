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

    /// How often the shown page reads the store again, so a run that starts, fails or is retried
    /// shows without a click. Only while the page shows: SwiftUI cancels the task when it goes.
    nonisolated static let refresh: Duration = .seconds(10)

    private static func page(_ model: AutomationsPage, _ palette: AutomationsPalette, _ actions: AutomationsPageView.Actions) -> AnyView {
        AnyView(AutomationsPageView(page: model, palette: palette, actions: actions).task {
            let clock = ContinuousClock()
            await model.reload(now: .now)
            // The page going away cancels the sleep, which ends the ticks.
            // wakeup-allow: the store has no change events the app can watch; two short CLI reads per 10 s, only while the page shows.
            for await _ in RefreshTicks(clock: clock, every: refresh) { await model.reload(now: .now) }
        })
    }
}

/// One tick per `every` until the task is cancelled: a sleep that throws on cancellation ends it.
private struct RefreshTicks: AsyncSequence, Sendable {
    typealias Element = Void
    let clock: ContinuousClock
    let every: Duration

    struct AsyncIterator: AsyncIteratorProtocol {
        let clock: ContinuousClock
        let every: Duration
        mutating func next() async -> Void? {
            // wakeup-allow: one bounded, cancellable wait per page refresh.
            let slept: Void? = try? await clock.sleep(for: every)
            return slept
        }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(clock: clock, every: every) }
}
