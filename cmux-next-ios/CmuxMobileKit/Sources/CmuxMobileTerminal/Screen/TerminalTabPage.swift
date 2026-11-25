#if os(iOS)
import CmuxMobileDesign
import SwiftUI
import UIKit

/// One terminal tab inside a workspace (CmuxTabsKit): the model and its
/// controller, kept alive while the tab exists so the Ghostty surface, the
/// scrollback and the input state survive tab switches and the grid.
@MainActor
public final class TerminalTabHost {
    public let model: TerminalModel
    private(set) lazy var controller: TerminalViewController = {
        let controller = TerminalViewController(model: self.model, chrome: .embedded)
        self.controllerMade = true
        if let place = self.handedPlace {
            self.handedPlace = nil
            controller.restoreScrollPlace(place)
        }
        return controller
    }()
    /// The page's controller exists (a host only ever shown as a grid card has none).
    private var controllerMade = false
    /// A place handed over before the controller was made.
    private var handedPlace: TerminalScrollPlace?

    public init(model: TerminalModel) {
        self.model = model
    }

    /// Where the reader is in the scrollback, kept by the tab when the warm
    /// set cools this host; nil while following the prompt or in a
    /// full-screen app.
    public func scrollPlace() -> TerminalScrollPlace? {
        controllerMade ? controller.scrollPlace() : handedPlace
    }

    /// The tab's previous host kept the reader's place: this host's first
    /// attach asks for the history above it and its replay puts the reader back.
    public func restoreScrollPlace(_ place: TerminalScrollPlace) {
        model.session.requestHistoryRows(place.rowsFromEnd)
        if controllerMade { controller.restoreScrollPlace(place) } else { handedPlace = place }
    }

    /// The tab grid is about to show this tab's card.
    /// Puts the page's views in (or out of) accessibility and hit-testing.
    /// SwiftUI's bridge reads a hosted view's `accessibilityElements`, so an
    /// empty list is set as well as the hidden flag.
    static func expose(_ view: UIView, _ exposed: Bool) {
        if view.accessibilityElementsHidden == exposed { view.accessibilityElementsHidden = !exposed }
        if exposed {
            if view.accessibilityElements != nil { view.accessibilityElements = nil }
        } else if (view.accessibilityElements?.isEmpty ?? false) == false {
            view.accessibilityElements = []
        }
        if view.isUserInteractionEnabled != exposed { view.isUserInteractionEnabled = exposed }
    }

    public func prepareCard() {
        // Runs in the tabs button's tap: the still is composed off the main
        // thread, never in the zoom's first frame.
        model.captureSnapshotOffMain()
        // The grid opens: the page becomes a picture in its card. TabsKit
        // does not lay the page out again until it zooms back in, so it is
        // taken out of accessibility and hit-testing here; the page's next
        // interactive update puts it back (V3-4, T-TABS-14).
        controller.viewIfLoaded.map { Self.expose($0, false) }
    }

    /// The page that last appeared. A retained tab can show on a new page before SwiftUI
    /// tears the old one down; only the current owner may change the size claim, so the
    /// outgoing page's late disappearance cannot release it from under the visible one.
    private var pageOwner: UUID?

    func pageAppeared(_ page: UUID, interactive: Bool) {
        pageOwner = page
        model.setPageShown(interactive)
    }

    func pageSettled(_ page: UUID, interactive: Bool) {
        guard pageOwner == page else { return }
        model.setPageShown(interactive)
    }

    func pageDisappeared(_ page: UUID) {
        guard pageOwner == page else { return }
        pageOwner = nil
        model.setPageShown(false)
    }
}

/// The embedded terminal page (SPEC 10 inside a workspace). TabsKit owns the
/// chrome: no navigation bar, the title and tab switching live in TabsKit's
/// toolbar and grid, and the terminal's actions in the page menu. The key bar
/// and composer rest where TabsKit puts a tab accessory (8 pt above the
/// toolbar) and ride the keyboard; in TUI mode the grid's bottom is pinned to
/// the composer and its top is clipped under the status bar.
public struct TerminalTabPage: View {
    let host: TerminalTabHost
    /// Status bar (top) and toolbar (bottom) over the page.
    let insets: EdgeInsets
    /// Where the chrome's cover ends this frame (a collapsed top bar's is above `insets.top`):
    /// the status scrim's height. Nil: `insets.top`.
    let chromeTop: CGFloat?
    /// The page is settled full screen (no zoom, swipe or open menu).
    let isInteractive: Bool
    /// The page is full screen, not zoomed out to the tab grid; true through
    /// an open menu, a swipe or an edit. The page turns sideways by this, so
    /// opening the page menu in landscape does not snap the app to portrait.
    let isOnPage: Bool
    /// This page's own identity for the host's size-claim ownership.
    @State private var pageID = UUID()

    public init(host: TerminalTabHost, insets: EdgeInsets, chromeTop: CGFloat? = nil, isInteractive: Bool,
                isOnPage: Bool? = nil) {
        self.host = host
        self.insets = insets
        self.chromeTop = chromeTop
        self.isInteractive = isInteractive
        self.isOnPage = isOnPage ?? isInteractive
    }

    /// How far above the page's bottom inset its rows end now: the dock at rest (key row
    /// and one-line composer) over the keyboard when it is up (``TerminalConnectingView``).
    private var rowsLift: CGFloat {
        let model = host.model
        let stack = TerminalDockMetrics().restingStackHeight(
            lineHeight: UIFont.preferredFont(forTextStyle: .body).lineHeight,
            visibility: TerminalDockVisibility(chromeHidden: model.chromeHidden, composerPresented: model.composerPresented))
        let keyboard = model.keyboardVisible ? TerminalKeyboardHeight.shared.height : 0
        return max(0, keyboard - insets.bottom) + stack + TerminalDocumentLayout.composerGap
    }

    public var body: some View {
        @Bindable var model = host.model
        EmbeddedTerminalControllerView(host: host, insets: insets, chromeTop: chromeTop, isInteractive: isInteractive)
            // Zoomed into the grid or mid-swipe, the page is a picture: its
            // composer and key bar are not controls then (R4-3).
            .accessibilityHidden(!isInteractive)
            // Only a page on screen, settled and taking input sizes the Mac's
            // terminal; the grid, a swipe away, another tab or leaving the
            // workspace release it (PROTOCOL.md, "Terminal size claims").
            .onAppear {
                host.pageAppeared(pageID, interactive: isInteractive)
                TerminalPageOrientation.shared.page(pageID, shows: isOnPage)
            }
            .onChange(of: isInteractive) { _, interactive in
                host.pageSettled(pageID, interactive: interactive)
            }
            .onChange(of: isOnPage) { _, onPage in
                // On the page, it turns with the phone (a menu, swipe or edit
                // keeps it turned); zoomed out, the grid is portrait.
                TerminalPageOrientation.shared.page(pageID, shows: onPage)
            }
            .onDisappear {
                host.pageDisappeared(pageID)
                TerminalPageOrientation.shared.page(pageID, shows: false)
            }
            // Full bleed top and bottom (the page's own insets place the rows);
            // sideways, the grid keeps clear of the Dynamic Island and the
            // corners (no side insets in portrait). The black fills them.
            .ignoresSafeArea(.all, edges: .vertical)
            .background(Color.black)
            // Not attached: the page as last seen on this phone, live. A warm surface keeps its
            // own rows; a rebuilt or restored one was fed its kept rows (`TerminalModel.seeded`):
            // both scroll and take keys at full opacity under nothing (Leo, 2026-11-24: "the
            // entire thing is somehow grayed out and I can't interact with anything at all").
            // Only a page with no rows of its own yet shows the Mac's screen text or a
            // skeleton, which take no touches. No status over the content or by the composer:
            // the title pill's subtitle says it after 10 s (`TerminalModel.connectionLine`).
            .overlay {
                Group {
                    if Self.showsCover(attached: model.connectionState.isAttached, seeded: model.seeded,
                                       drewLiveOutput: model.drewLiveOutput, heldFrame: model.coldFrame != nil) {
                        // Once attached the cover stays until the live rows are drawn, then
                        // goes in one frame: a cut, never a fade over live rows (R3-4). Its
                        // rows are laid out for the page as it is now (keyboard up or down).
                        TerminalConnectingView(topInset: insets.top, screenText: model.cardScreenText,
                                               rowsLift: rowsLift, rows: model.coldFrameRows, rowsMeasured: model.coldFrameMeasured)
                            .ignoresSafeArea()
                            .padding(.bottom, insets.bottom)
                            .transition(.identity)
                            .placeholderBound("terminal.page.connecting", .milliseconds(2000))
                    }
                }
                .allowsHitTesting(isInteractive)
                .accessibilityHidden(!isInteractive)
            }
            // Presented by the controller (UIKit), not with `.sheet` here: a
            // SwiftUI sheet presented from inside the TabsKit page left the
            // controller's keyboard layout guide at 172 pt with no keyboard
            // (the stack jumped to the top) until the next keyboard change.
            .onChange(of: model.showArtifacts) { _, shown in
                if shown { host.controller.presentArtifacts() } else { host.controller.dismissArtifacts() }
            }
    }
}

extension TerminalTabPage {
    /// Whether the page draws the connecting cover (the Mac's screen text or a skeleton) over
    /// its surface: only while the surface has no rows of its own, neither fed from the kept
    /// page nor drawn from the Mac, and never a still picture (it takes no scroll or tap).
    static func showsCover(attached: Bool, seeded: Bool, drewLiveOutput: Bool, heldFrame: Bool) -> Bool {
        guard !seeded, !drewLiveOutput else { return false }
        return !attached || heldFrame
    }
}

/// The tab's grid card: the last snapshot of the page (no second live
/// surface), or a quiet placeholder before the page has been on screen.
public struct TerminalTabCard: View {
    let model: TerminalModel
    let insets: EdgeInsets

    public init(model: TerminalModel, insets: EdgeInsets) {
        self.model = model
        self.insets = insets
    }

    public var body: some View {
        // A picture of the page: TabsKit labels the card; nothing inside it
        // is a control (R4-3).
        cardContent.accessibilityHidden(true)
    }

    /// What the card draws: also read by the UI tests' face probe (`TabCardFaceRecord`).
    public var content: TerminalCardContent {
        let started = model.controller?.started == true
        return TerminalCardContent.choose(sessionStarted: started,
                                          hasSnapshot: model.snapshot != nil, screenText: model.cardScreenText,
                                          screenTextIsNewer: model.cardScreenTextIsNewer)
    }

    private var cardContent: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                // The page's ground: the Mac's wallpaper under the terminal background's tint, else that background.
                CmuxMobileBackdrop(background: Color(uiColor: (model.hostTheme
                        ?? CmuxMobileTerminalThemes.shared.theme(for: model.hostMacID))?.backgroundColor
                    ?? CmuxMobileGhosttyApp.background))
                switch content {
                case .screenText:
                    TerminalCardScreenText(text: model.cardScreenText ?? "", topInset: insets.top, width: geo.size.width)
                case .snapshot, .savedFrame:
                    if let image = model.snapshot {
                    let scale = geo.size.width / max(1, image.size.width)
                    // A still holds the rows only (qa11): the card ends just under the
                    // last row, which rests on the dock's top (the key row) at rest.
                    let composer = TerminalDockMetrics().restingStackHeight(
                        lineHeight: UIFont.preferredFont(forTextStyle: .body).lineHeight,
                        visibility: TerminalDockVisibility(chromeHidden: model.chromeHidden, composerPresented: model.composerPresented))
                    let crop = TerminalCardCrop(width: geo.size.width, imageHeight: image.size.height * scale,
                                                bottomTrim: max(0, insets.bottom + composer - 6) * scale)
                    // The newest rows and the prompt at the card's bottom edge (V5-6). A frame
                    // from an earlier launch is the last-known page, shown as it is (not
                    // dimmed) until the Mac's screen replaces it.
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: geo.size.width, height: crop.imageHeight)
                        .offset(y: crop.imageTop)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                        .clipped()
                        // A frame from an earlier launch stands in at full strength until the
                        // Mac's screen arrives (T-TABS-01): never greyed (Leo, 2026-11-24:
                        // "the graying out of workspaces, nah let's not do that").
                        .opacity(content.drawnOpacity)
                    }
                case .nothing:
                    // Nothing known yet: the terminal's background, no stand-in.
                    EmptyView()
                }
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

/// The Mac's screen as text in a grid card: the page's monospaced rows at the
/// page's column count, so it reads like the terminal it stands for.
struct TerminalCardScreenText: View {
    let text: String
    let topInset: CGFloat
    let width: CGFloat

    var body: some View {
        let all = TerminalCardScreenLines.shown(text, capacity: .max)
        let columns = max(40, all.map(\.count).max() ?? 40)
        // A Menlo cell is about 0.6 em wide.
        let size = min(13, max(5, (width - 12) / (CGFloat(columns) * 0.6)))
        // Only the card's visible part counts: the last rows that fit, the prompt at the bottom (qa11).
        let lineHeight = UIFont.monospacedSystemFont(ofSize: size, weight: .regular).lineHeight
        let shown = TerminalCardScreenLines.shown(text, capacity: TerminalCardScreenLines.capacity(
            visibleHeight: width * TerminalCardCrop.cardAspect, topInset: topInset, lineHeight: lineHeight))
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                Text(String(line).isEmpty ? " " : String(line))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .font(.system(size: size, design: .monospaced))
        .foregroundStyle(Color.white.opacity(0.88))
        .padding(.horizontal, 6)
        .padding(.top, topInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }
}

struct EmbeddedTerminalControllerView: UIViewControllerRepresentable {
    let host: TerminalTabHost
    let insets: EdgeInsets
    var chromeTop: CGFloat?
    let isInteractive: Bool

    func makeUIViewController(context: Context) -> EmbeddedTerminalContainer {
        EmbeddedTerminalContainer(terminal: host.controller)
    }

    func updateUIViewController(_ container: EmbeddedTerminalContainer, context: Context) {
        container.loadViewIfNeeded()
        let controller = container.terminal
        guard controller.parent === container else { return }
        controller.setEmbeddedInsets(UIEdgeInsets(top: insets.top, left: 0, bottom: insets.bottom, right: 0))
        // The scrim rides the top bar's collapse inside the same SwiftUI animation, so the
        // band the bar gave back shows the rows under it instead of a solid strip.
        let scrimTop = chromeTop ?? insets.top
        if controller.needsChromeTop(scrimTop) {
            context.animate {
                controller.setChromeTop(scrimTop)
                controller.view.layoutIfNeeded()
            }
        }
        // Zoomed into the grid or mid-swipe the page is a picture: SwiftUI's
        // `accessibilityHidden` does not reach a representable's UIKit views,
        // so its composer, Return and Scroll to bottom stayed exposed and took
        // taps and VoiceOver focus inside the card (V3-4, T-TABS-14).
        TerminalTabHost.expose(controller.view, isInteractive)
        // A zoom to the grid, a swipe or the page menu takes the page: the
        // keyboard goes, as in Safari.
        if !isInteractive, host.model.keyboardVisible {
            controller.hideKeyboard()
        }
    }

    static func dismantleUIViewController(_ controller: EmbeddedTerminalContainer, coordinator: ()) {}
}

/// SwiftUI owns one container per representable lifetime. The terminal survives
/// those lifetimes, so returning it directly lets an outgoing representable's
/// delayed teardown detach the controller already used by the incoming page.
/// Only the child moves; tearing down the old container cannot remove it again.
final class EmbeddedTerminalContainer: UIViewController {
    let terminal: TerminalViewController

    init(terminal: TerminalViewController) {
        self.terminal = terminal
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        if terminal.parent != nil {
            terminal.willMove(toParent: nil)
            terminal.view.removeFromSuperview()
            terminal.removeFromParent()
        }
        addChild(terminal)
        terminal.view.translatesAutoresizingMaskIntoConstraints = true
        terminal.view.frame = view.bounds
        terminal.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(terminal.view)
        terminal.didMove(toParent: self)
    }
}
#endif
