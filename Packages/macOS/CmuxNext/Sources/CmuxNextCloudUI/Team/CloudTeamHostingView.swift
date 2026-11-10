public import AppKit
public import CmuxNextActions
public import CmuxNextDesign
import CmuxNextCompat

/// The Team section's view in the sidebar: AppKit rows of ``CloudTeamSessionStore`` under the four
/// filters (``CloudTeamSectionView``). It redraws in its window's theme on an appearance change
/// and tells the sidebar when its height changes (rows came or went).
@MainActor
public final class CloudTeamHostingView: NSView {
    /// Runs a catalog action with these arguments as the person's run.
    public typealias Perform = @MainActor (ActionID, [String: ActionValue]) -> Void
    /// A row's right-click menu, whose rows run catalog actions on that session; nil for none.
    public typealias RowMenu = @MainActor (CloudTeamSession, [CloudTeamMember]) -> NSMenu?

    private let store: CloudTeamSessionStore
    private let tokens: @MainActor () -> ThemeTokens
    let section: CloudTeamSectionView
    private var shownHeight: CGFloat = 0
    /// The sidebar re-asks the height (`SidebarAppSectionProvider.onContentChange`).
    public var onHeightChange: (() -> Void)?

    public init(store: CloudTeamSessionStore, tokens: @escaping @MainActor () -> ThemeTokens,
                perform: @escaping Perform, open: @escaping @MainActor (CloudTeamSession) -> Void,
                menu: @escaping RowMenu = { _, _ in nil }) {
        self.store = store
        self.tokens = tokens
        section = CloudTeamSectionView(store: store, colors: CloudTeamColors(tokens: tokens()),
                                       actions: .init(perform: perform, open: open, menu: menu))
        super.init(frame: .zero)
        section.translatesAutoresizingMaskIntoConstraints = false
        addSubview(section)
        NSLayoutConstraint.activate([
            section.leadingAnchor.constraint(equalTo: leadingAnchor), section.trailingAnchor.constraint(equalTo: trailingAnchor),
            section.topAnchor.constraint(equalTo: topAnchor), section.bottomAnchor.constraint(equalTo: bottomAnchor),
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
        section.colors = CloudTeamColors(tokens: tokens())
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
