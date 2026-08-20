import AppKit
import SwiftUI

/// Dwell-then-present hover card used by icon-rail sidebar columns.
///
/// The anchor is a transparent, hit-test-invisible tracking view overlaid on
/// a row. After the pointer rests on the row for `dwell`, it presents an
/// NSPopover hosting SwiftUI card content next to the row; leaving the row
/// cancels the pending presentation or closes the card. The dwell timer is a
/// cancellable `Task` whose lifetime is wired to pointer exit and view
/// teardown (no fire-and-forget timers).
struct SidebarHoverCardAnchor<Card: View>: NSViewRepresentable {
    var isEnabled: Bool
    var preferredEdge: NSRectEdge = .maxX
    @ViewBuilder var card: () -> Card

    func makeNSView(context: Context) -> SidebarHoverCardTrackingView {
        SidebarHoverCardTrackingView()
    }

    func updateNSView(_ view: SidebarHoverCardTrackingView, context: Context) {
        view.preferredEdge = preferredEdge
        view.cardViewControllerProvider = { [card] in
            let controller = NSHostingController(rootView: card())
            controller.view.layoutSubtreeIfNeeded()
            return controller
        }
        view.isEnabled = isEnabled
    }
}

@MainActor
final class SidebarHoverCardTrackingView: NSView {
    static let dwell: Duration = .milliseconds(350)

    var preferredEdge: NSRectEdge = .maxX
    var cardViewControllerProvider: (() -> NSViewController)?
    var isEnabled = false {
        didSet {
            if !isEnabled { cancelAndDismiss() }
        }
    }

    private var dwellTask: Task<Void, Never>?
    private var popover: NSPopover?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled, cardViewControllerProvider != nil else { return }
        dwellTask?.cancel()
        dwellTask = Task { [weak self] in
            try? await Task.sleep(for: Self.dwell)
            guard !Task.isCancelled else { return }
            self?.presentCard()
        }
    }

    override func mouseExited(with event: NSEvent) {
        cancelAndDismiss()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { cancelAndDismiss() }
    }

    private func presentCard() {
        guard window != nil, popover == nil,
              let controller = cardViewControllerProvider?()
        else { return }
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.animates = true
        popover.contentViewController = controller
        popover.contentSize = controller.view.fittingSize
        popover.show(relativeTo: bounds, of: self, preferredEdge: preferredEdge)
        self.popover = popover
    }

    private func cancelAndDismiss() {
        dwellTask?.cancel()
        dwellTask = nil
        popover?.close()
        popover = nil
    }
}

/// Shared visual shell so machine and workspace hover cards read as one
/// component: title line with icon, then compact secondary rows.
struct SidebarHoverCardShell<Icon: View, Rows: View>: View {
    @ViewBuilder let icon: () -> Icon
    let title: String
    @ViewBuilder let rows: () -> Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                icon()
                    .frame(width: 16, height: 16)
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(2)
            }
            rows()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minWidth: 168, maxWidth: 280, alignment: .leading)
    }
}

struct SidebarHoverCardDetailRow: View {
    let text: String
    var secondary = true

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(secondary ? Color.secondary : Color.primary)
            .lineLimit(2)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
