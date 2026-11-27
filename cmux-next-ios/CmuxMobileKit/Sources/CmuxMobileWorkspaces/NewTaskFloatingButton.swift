#if os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// New Task: the floating compose button at the bottom trailing corner of Workspaces and Feed,
/// above the tab bar, where Slack puts its compose button (2026-11-18). It opens the task
/// composer (a prompt, the agents that run it and where). It used to be the first row of New
/// Workspace's long-press menu, hidden behind a press and crowded by fourteen other rows.
///
/// The same Liquid Glass as the tab bar under it (Aziz, 2026-11-19: "a glass button just like
/// the tab bar for consistency"): clear glass, the symbol in `label`, no accent fill.
public struct NewTaskFloatingButton: View {
    let symbol: String
    let action: () -> Void

    public init(symbol: String = NewTaskFloatingButton.symbol, action: @escaping () -> Void) {
        self.symbol = symbol
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title2.weight(.medium))
                .foregroundStyle(theme.colors.label.color)
                .frame(width: Self.size, height: Self.size)
                .contentShape(.circle)
        }
        // The same circular wash it had (cornerRadius: size / 2), now named.
        .buttonStyle(.cmuxPressFillCircle)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("New Task")
        .accessibilityHint("Write a prompt and choose the agents that run it")
        .accessibilityIdentifier("workspaces.newTask")
    }

    /// Slack's and Material's compose button: 56 pt, above the 44 pt minimum target.
    public static let size: CGFloat = 56
    /// Its gap above the tab bar.
    public static let gap: CGFloat = 12
    /// What a list under it leaves free below its last row, so that row scrolls clear of it.
    public static let room: CGFloat = size + gap

    /// The button's symbol. DEBUG builds take `-cmux-mobile-new-task-symbol NAME` (the symbol
    /// exploration's captures, 2026-11-19).
    public static var symbol: String {
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "-cmux-mobile-new-task-symbol"),
           CommandLine.arguments.indices.contains(index + 1) {
            return CommandLine.arguments[index + 1]
        }
        #endif
        return "plus"
    }
}

public extension View {
    /// The New Task button over a tab (Workspaces, Feed) and the composer it opens.
    ///
    /// Placement: an overlay on the tab's whole content (its `NavigationStack`), aligned bottom
    /// trailing. The tab's frame is the screen, and its bottom safe area is the tab bar, so the
    /// button sits `NewTaskFloatingButton.gap` above the tab bar and `sideMargin` in from the
    /// trailing edge whatever the list inside shows (rows, an empty or a loading page). The
    /// keyboard's safe area is ignored, so a keyboard never lifts it into the middle of the
    /// screen. Lists under it get `NewTaskFloatingButton.room` below their last row through
    /// `cmuxMobileFloatingBottomRoom`.
    ///
    /// - Parameters:
    ///   - atRoot: the tab shows its root page (nothing pushed); a pushed page hides the button.
    ///   - started: the workspaces a started task made.
    func newTaskButton(creator: WorkspaceCreator, store: AppStore, atRoot: Bool,
                       started: @escaping ([Workspace]) -> Void) -> some View {
        modifier(NewTaskButtonHost(creator: creator, store: store, atRoot: atRoot, started: started))
    }
}

private struct NewTaskButtonHost: ViewModifier {
    let creator: WorkspaceCreator
    let store: AppStore
    let atRoot: Bool
    let started: ([Workspace]) -> Void
    @State private var composing = false
    @State private var macText = MacFilterMemo()

    /// Some Mac can start agents now (none: no button; New Workspace still starts terminals).
    private var canStart: Bool { !creator.taskMacs.isEmpty }
    private var shows: Bool { canStart && atRoot }

    func body(content: Content) -> some View {
        content
            .environment(\.cmuxMobileFloatingBottomRoom, canStart ? NewTaskFloatingButton.room : 0)
            .overlay {
                // A full-size layer that ignores the keyboard (so its bottom stays the tab bar's
                // edge with a keyboard up), the button at its bottom trailing corner. Only the
                // button takes touches.
                ZStack(alignment: .bottomTrailing) {
                    Color.clear.allowsHitTesting(false)
                    if shows {
                        NewTaskFloatingButton { composing = true }
                            .padding(.trailing, theme.metrics.sideMargin)
                            .padding(.bottom, NewTaskFloatingButton.gap)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .ignoresSafeArea(.keyboard, edges: .bottom)
            }
            // Gone at once when a page is pushed (not shrinking over the page coming in);
            // back with its spring once a page has left.
            .animation(shows ? theme.motion.snap.animation.unlessReduceMotion : nil, value: shows)
            #if DEBUG
            // `-cmux-mobile-open-new-task`: New Task opens at launch (its captures at Accessibility sizes).
            .task {
                guard CommandLine.arguments.contains("-cmux-mobile-open-new-task"), !DebugLaunch.openedNewTask, canStart else { return }
                DebugLaunch.openedNewTask = true
                composing = true
            }
            #endif
            // Full screen, as classic's task composer: a prompt canvas with its controls above the keyboard.
            .fullScreenCover(isPresented: $composing) {
                TaskComposerScreen(creator: creator, sameNames: macText.names(MacRoster.accountMacs(store.teams)),
                                   started: started, close: { composing = false })
            }
    }
}
#endif
