public import AppKit
public import CmuxNextDesign
import CmuxNextCompat
import SwiftUI

/// The Team section's AppKit view in the sidebar: a container around ``CloudTeamSectionView``.
/// It redraws in its window's theme on an appearance change (as AutomationsHostingView does)
/// and tells the sidebar when its height changes (rows came or went).
@MainActor
public final class CloudTeamHostingView: NSView {
    private let store: CloudTeamSessionStore
    private let tokens: @MainActor () -> ThemeTokens
    private let perform: CloudTeamSectionView.Perform
    private let open: @MainActor (CloudTeamSession) -> Void
    private var palette: AutomationsPalette
    private let hosting: NSHostingView<CloudTeamSectionView>
    private var shownHeight: CGFloat = 0
    /// The sidebar re-asks the height (`SidebarAppSectionProvider.onContentChange`).
    public var onHeightChange: (() -> Void)?

    public init(store: CloudTeamSessionStore, tokens: @escaping @MainActor () -> ThemeTokens,
                perform: @escaping CloudTeamSectionView.Perform, open: @escaping @MainActor (CloudTeamSession) -> Void) {
        self.store = store
        self.tokens = tokens
        self.perform = perform
        self.open = open
        let palette = AutomationsPalette(tokens: tokens())
        self.palette = palette
        hosting = NSHostingView(rootView: CloudTeamSectionView(store: store, palette: palette, perform: perform, open: open))
        super.init(frame: .zero)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor), hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor), hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        shownHeight = preferredHeight
        watchHeight()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The height the section asks for now.
    public var preferredHeight: CGFloat { CloudTeamSectionView.height(for: store) }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let next = AutomationsPalette(tokens: tokens())
        guard next != palette else { return }
        palette = next
        hosting.rootView = CloudTeamSectionView(store: store, palette: next, perform: perform, open: open)
    }

    /// One sidebar re-layout per change of the section's height (rows came or went).
    private func watchHeight() {
        let store = store
        // task-owner: the view's one height observation; it ends once the view is released.
        Task { [weak self] in
            for await height in ObservationStream({ CloudTeamSectionView.height(for: store) }) {
                // A released view ends its watch at the next change.
                guard let self else { return }
                guard height != shownHeight else { continue }
                shownHeight = height
                onHeightChange?()
            }
        }
    }
}
