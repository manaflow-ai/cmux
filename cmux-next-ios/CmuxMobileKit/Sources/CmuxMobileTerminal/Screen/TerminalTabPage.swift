#if os(iOS)
import SwiftUI
import UIKit

/// One terminal tab inside a workspace (CmuxTabsKit): the model and its
/// controller, kept alive while the tab exists so the Ghostty surface, the
/// scrollback and the input state survive tab switches and the grid.
@MainActor
public final class TerminalTabHost {
    public let model: TerminalModel
    private(set) lazy var controller = TerminalViewController(model: model, chrome: .embedded)

    public init(model: TerminalModel) {
        self.model = model
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
        model.captureSnapshot()
        // The grid opens: the page becomes a picture in its card. TabsKit
        // does not lay the page out again until it zooms back in, so it is
        // taken out of accessibility and hit-testing here; the page's next
        // interactive update puts it back (V3-4, T-TABS-14).
        controller.viewIfLoaded.map { Self.expose($0, false) }
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
    /// The page is settled full screen (no zoom, swipe or open menu).
    let isInteractive: Bool

    public init(host: TerminalTabHost, insets: EdgeInsets, isInteractive: Bool) {
        self.host = host
        self.insets = insets
        self.isInteractive = isInteractive
    }

    public var body: some View {
        @Bindable var model = host.model
        EmbeddedTerminalControllerView(host: host, insets: insets, isInteractive: isInteractive)
            // Zoomed into the grid or mid-swipe, the page is a picture: its
            // composer and key bar are not controls then (R4-3).
            .accessibilityHidden(!isInteractive)
            // Only a page on screen, settled and taking input sizes the Mac's
            // terminal; the grid, a swipe away, another tab or leaving the
            // workspace release it (PROTOCOL.md, "Terminal size claims").
            .onAppear { host.model.setPageShown(isInteractive) }
            .onChange(of: isInteractive) { _, interactive in host.model.setPageShown(interactive) }
            .onDisappear { host.model.setPageShown(false) }
            .ignoresSafeArea()
            .background(Color.black)
            // Not attached yet: the honest placeholder over the empty surface.
            .overlay {
                Group {
                    if model.connectionState.keepsWarmFrame {
                        // Reattaching: a warm surface keeps its last frame live
                        // under no overlay; a cold tab shows its frame dimmed. The
                        // title pill says "Reattaching…" after 400 ms (SPEC P5).
                        TerminalConnectingView(state: model.connectionState, topInset: insets.top,
                                               lastFrame: model.coldFrame,
                                               showsLabel: !model.connectionState.showsProgress,
                                               showsPlaceholder: false, retry: model.reconnect)
                            .ignoresSafeArea()
                            .padding(.bottom, insets.bottom)
                    } else if !model.connectionState.isAttached || model.coldFrame != nil {
                        // One view from "Connecting…" to live (R2-5): a tab back
                        // from the warm set or a cold restore shows its last frame
                        // at once; once attached the label goes, the frame stays
                        // until the live rows are drawn, then goes in one frame: a cut,
                        // never a fade over live rows at other positions (R3-4).
                        // (Two views crossfading here flashed the title pill grey.)
                        TerminalConnectingView(state: model.connectionState, topInset: insets.top, lastFrame: model.coldFrame,
                                               showsLabel: !model.connectionState.isAttached, retry: model.reconnect)
                            .ignoresSafeArea()
                            .padding(.bottom, insets.bottom)
                            .transition(.identity)
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

/// The tab's grid card: the last snapshot of the page (no second live
/// surface), or a quiet placeholder before the page has been on screen.
public struct TerminalTabCard: View {
    let model: TerminalModel
    let insets: EdgeInsets

    private var isReattaching: Bool {
        model.connectionState.keepsWarmFrame
    }

    public init(model: TerminalModel, insets: EdgeInsets) {
        self.model = model
        self.insets = insets
    }

    public var body: some View {
        // A picture of the page: TabsKit labels the card; nothing inside it
        // is a control (R4-3).
        cardContent.accessibilityHidden(true)
    }

    private var cardContent: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color(uiColor: CmuxMobileGhosttyApp.background)
                let started = model.controller?.started == true
                let content = TerminalCardContent.choose(sessionStarted: started,
                                                         connecting: model.connectionState.cardShowsConnecting(sessionStarted: started),
                                                         hasSnapshot: model.snapshot != nil, screenText: model.cardScreenText,
                                                         screenTextIsNewer: model.cardScreenTextIsNewer)
                switch content {
                case .connecting:
                    TerminalConnectingView(state: model.connectionState, topInset: insets.top, lastFrame: model.snapshot,
                                           showsLabel: !isReattaching)
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
                    // The newest rows and the prompt at the card's bottom edge (V5-6).
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: geo.size.width, height: crop.imageHeight)
                        .offset(y: crop.imageTop)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                        .clipped()
                        // A frame from an earlier launch stands in, dimmed like a page
                        // that is not live, until the Mac's screen arrives (T-TABS-01).
                        .opacity(content.isCurrent ? 1 : 0.55)
                    }
                case .placeholder:
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(model.programName) — \(model.title)")
                            .foregroundStyle(Color.white.opacity(0.45))
                        HStack(spacing: 0) {
                            Text("$ ")
                            Rectangle().fill(Color.white.opacity(0.85)).frame(width: 8, height: 15)
                        }
                    }
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .padding(.horizontal, 12)
                    .padding(.top, insets.top + 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
    let isInteractive: Bool

    func makeUIViewController(context: Context) -> TerminalViewController {
        let controller = host.controller
        // The same controller comes back when the tab is shown again; a page
        // being replaced may still hold it for a moment.
        if controller.parent != nil {
            controller.willMove(toParent: nil)
            controller.view.removeFromSuperview()
            controller.removeFromParent()
        }
        return controller
    }

    func updateUIViewController(_ controller: TerminalViewController, context: Context) {
        controller.setEmbeddedInsets(UIEdgeInsets(top: insets.top, left: 0, bottom: insets.bottom, right: 0))
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

    static func dismantleUIViewController(_ controller: TerminalViewController, coordinator: ()) {}
}
#endif
