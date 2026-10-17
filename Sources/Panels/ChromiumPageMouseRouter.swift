import AppKit
import CmuxBrowser
import CmuxCEF

/// Routes the mouse around Chromium pages where cmux's own window must get
/// it, as next to a WebKit page:
///
/// - **Divider bands.** A pane divider's grab area reaches 8 pt into the panes
///   beside it (`PortalSplitDividerRegion.dividerHitExpansion`). Over a
///   Chromium page that part belonged to the page window. While the pointer
///   is in it, the page leaves a hole there (`ChromiumDividerBands`), so the
///   divider shows its resize cursor and takes the press along its full band.
/// - **Drags from the cmux window.** While a press that began in the cmux
///   window is held (a tab dragged from the pane tab bar), its page windows
///   ignore the mouse (`ChromiumPagePressGate`), so a tab dragged over a
///   Chromium pane reaches the pane's drop targets: the split drop zone shows
///   (through the hole `BrowserPanelView` cuts for it) and takes the drop.
///
/// One local monitor for the process, installed once a Chromium page shows;
/// it returns every event unchanged and does nothing in a window without a
/// Chromium page.
@MainActor
final class ChromiumPageMouseRouter {
    static let shared = ChromiumPageMouseRouter()

    private static let dividerBandSource = "dividerBand"
    private var monitor: Any?
    private let pressGate = ChromiumPagePressGate()
    /// The window whose page shows a divider-band hole.
    private weak var bandWindow: NSWindow?

    private init() {}

    /// Starts routing (idempotent).
    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseUp, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        guard let eventWindow = event.window,
              let window = eventWindow.chromiumActingWindow(fallback: nil),
              let registry = CEFWindowOcclusion.existing(for: window) else {
            clearBand()
            return
        }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // A press in the cmux window itself, not in one of its pages.
            if eventWindow === window { pressGate.pressBegan(in: window) }
        default:
            updateDividerBand(in: window, registry: registry)
        }
    }

    private func updateDividerBand(in window: NSWindow, registry: CEFWindowOcclusion) {
        if let bandWindow, bandWindow !== window { clearBand() }
        let hosts = registry.hostViews.filter { !$0.isHiddenOrHasHiddenAncestor && !$0.bounds.isEmpty }
        let band = hosts.isEmpty ? nil : ChromiumDividerBands.band(
            at: window.convertPoint(fromScreen: NSEvent.mouseLocation),
            pages: hosts.map { $0.convert($0.bounds, to: nil) },
            dividers: Self.dividers(around: hosts)
        )
        registry.setRects(band.map { [$0.rect] } ?? [], for: Self.dividerBandSource)
        bandWindow = band == nil ? nil : window
        if let band {
            // The page set its own cursor last; the divider's shows now.
            (band.isVertical ? PortalDividerCursorKind.vertical : .horizontal).cursor.set()
        }
    }

    private func clearBand() {
        guard let window = bandWindow else { return }
        bandWindow = nil
        CEFWindowOcclusion.existing(for: window)?.setRects([], for: Self.dividerBandSource)
    }

    /// The dividers of every split view around the pages: only a split that
    /// holds a page has a divider whose grab area reaches into it.
    private static func dividers(around hosts: [CEFHostView]) -> [ChromiumDividerBands.Divider] {
        var seen = Set<ObjectIdentifier>()
        var dividers: [ChromiumDividerBands.Divider] = []
        for host in hosts {
            var ancestor = host.superview
            while let view = ancestor {
                if let split = view as? NSSplitView, seen.insert(ObjectIdentifier(split)).inserted {
                    for index in 0..<max(0, split.arrangedSubviews.count - 1) {
                        guard let rect = PortalSplitDividerRegion.dividerHitRectInWindow(in: split, dividerIndex: index)
                        else { continue }
                        dividers.append(ChromiumDividerBands.Divider(hitRect: rect, isVertical: split.isVertical))
                    }
                }
                ancestor = view.superview
            }
        }
        return dividers
    }
}
