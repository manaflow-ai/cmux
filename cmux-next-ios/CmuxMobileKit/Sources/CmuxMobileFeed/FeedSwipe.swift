#if os(iOS)
import CmuxMobileAgentChat
import CmuxMobileDesign
import SwiftUI
import UIKit

/// One swipe action (Mail style: tinted, icon over a short label). Tints
/// come from `FeedSwipeTint`, which reads well in light and dark mode.
struct FeedSwipeAction: Identifiable {
    var id: String
    var title: String
    var systemImage: String
    var tint: Color
    /// The action removes the row (Done): it runs while the row is slid out; others run after it slides back.
    var removesRow = false
    var action: () -> Void
}

/// Swipe action fills: UIKit's semantic system colors (the ones Mail and
/// Messages use), which adapt to light and dark mode. White labels stay
/// legible on every one of them in both modes.
enum FeedSwipeTint {
    /// Destructive (Deny, Decline): the system destructive red.
    static var destructive: Color { Color(uiColor: .systemRed) }
    /// Archive-like (Done), as Mail's Archive.
    static var archive: Color { Color(uiColor: .systemPurple) }
    /// Read state, as Mail's Unread.
    static var read: Color { Color(uiColor: .systemBlue) }
    /// Approve (Allow).
    static var approve: Color { Color(uiColor: .systemGreen) }
}

/// Which row's actions are showing, so opening one closes the other and a
/// scroll closes them all (owned by the Feed screen).
@MainActor
@Observable
final class FeedSwipeCoordinator {
    var openID: String?
    /// Demo driver requests: reveal the actions, or perform an action as a full swipe.
    var demoReveal: String?
    var demoPerform: (id: String, action: String)?
    var demoSerial = 0
}

/// Trailing swipe actions on a row outside `List` (iOS Mail conventions): a
/// leftward pan that never fights vertical scrolling, actions revealed under
/// the row, a full swipe past 60 % of the width performs the outermost action
/// with a haptic, rubber banding past the end, tap to close. (iOS 27's
/// `swipeActionsContainer()` covers this in SwiftUI, but the deployment
/// target is iOS 26.)
///
/// There is no leading edge: a rightward pan on a tab root opens the team
/// drawer (SPEC 3.3, swipe rules), so the row's pan does not begin for a
/// rightward drag unless it is closing open actions.
struct FeedSwipeRow<Content: View>: View {
    let id: String
    let actions: [FeedSwipeAction]
    let coordinator: FeedSwipeCoordinator
    @ViewBuilder let content: Content

    @State private var offset: CGFloat = 0
    @State private var dragStart: CGFloat?
    @State private var width: CGFloat = 0
    @State private var height: CGFloat = 0
    /// A full swipe is armed: the row haptic fires as it arms (UIKit's
    /// generator, not `.sensoryFeedback`, whose per-row setup ran for every
    /// row that scrolled in).
    @State private var armed = false {
        didSet { if armed, !oldValue { UIImpactFeedbackGenerator(style: .medium).impactOccurred() } }
    }

    private var isOpen: Bool { offset != 0 }
    /// This row's entry in ``RowSwipeActions``, unique to this Feed screen.
    private var registrationKey: String { "feed.\(ObjectIdentifier(coordinator)).\(id)" }
    private var revealWidth: CGFloat { RowSwipeActionStyle.standard.revealWidth(count: actions.count) }
    /// Past the open row's resting reveal, so an open row never arms on a small drag.
    private var fullThreshold: CGFloat { max(width * 0.6, 160, revealWidth + 40) }

    var body: some View {
        content
            .offset(x: offset)
            .overlay {
                // While open, a tap anywhere on the row closes it instead of opening the event.
                if isOpen {
                    Color.clear.contentShape(.rect).onTapGesture { close() }
                        .offset(x: offset)
                }
            }
            .background(alignment: .trailing) {
                if offset < 0 { actionStrip }
            }
            .clipped()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { width = $0.width; height = $0.height }
            .gesture(HorizontalPan(isOpen: isOpen, onChange: dragChanged, onEnd: dragEnded))
            .onChange(of: coordinator.openID) { _, open in
                if open != id, isOpen { withAnimation(.cmuxMobileSnappy) { offset = 0 } }
            }
            .onChange(of: coordinator.demoSerial) { runDemo() }
            // Open actions take a rightward swipe before the team drawer does.
            .onChange(of: isOpen) { _, open in
                RowSwipeActions.shared.setOpen(registrationKey, close: open ? { [coordinator] in coordinator.openID = nil } : nil)
            }
            // A row scrolled away or left behind on another tab closes, so no open row
            // outlives its registration (the drawer would open over it).
            .onDisappear {
                offset = 0
                if coordinator.openID == id { coordinator.openID = nil }
                RowSwipeActions.shared.setOpen(registrationKey, close: nil)
            }
            .accessibilityActions {
                ForEach(actions) { action in
                    Button(action.title, action: action.action)
                }
            }
    }

    /// The same buttons `List`'s swipe actions draw on Workspaces and Home
    /// (``RowSwipeActionButton``): tinted capsules with their titles under
    /// them, inset from the row's edge, centered on the row. They grow
    /// together as the row slides; an armed full swipe gives the outermost
    /// one all the room.
    private var actionStrip: some View {
        let revealed = abs(offset)
        let style = RowSwipeActionStyle.standard
        let each = style.buttonWidth(revealed: revealed, count: actions.count)
        return HStack(spacing: armed ? 0 : style.spacing) {
            ForEach(actions.reversed()) { action in
                let isOutermost = action.id == actions.first?.id
                let width = armed ? (isOutermost ? style.fullSwipeWidth(revealed: revealed) : 0) : each
                RowSwipeActionButton(title: action.title, systemImage: action.systemImage, tint: action.tint, width: width, maxHeight: height) {
                    perform(action)
                }
                .opacity(armed && !isOutermost ? 0 : 1)
                .accessibilityIdentifier("feed.swipe.\(action.id)")
            }
        }
        .padding(.trailing, style.trailingInset)
        .frame(width: revealed, alignment: .trailing)
        .frame(maxHeight: .infinity)
        .clipped()
        .animation(.cmuxMobileSnappy, value: armed)
    }

    private func dragChanged(_ translation: CGFloat) {
        if dragStart == nil {
            dragStart = offset
            coordinator.openID = id
        }
        var next = min((dragStart ?? 0) + translation, 0)
        if actions.isEmpty { next = 0 }
        // Rubber band past the full-swipe point.
        let limit = width * 0.9
        if abs(next) > limit { next = (next > 0 ? 1 : -1) * (limit + (abs(next) - limit) * 0.25) }
        offset = next
        armed = abs(next) > fullThreshold
    }

    private func dragEnded(_ translation: CGFloat, _ velocity: CGFloat) {
        dragStart = nil
        if armed, let first = actions.first {
            perform(first)
            return
        }
        let projected = abs(min(offset + velocity * 0.12, 0))
        withAnimation(.cmuxMobileSnappy) {
            offset = projected > revealWidth / 2 && (velocity <= 0 || abs(offset) > revealWidth / 2) ? -revealWidth : 0
        }
        if offset == 0, coordinator.openID == id { coordinator.openID = nil }
    }

    /// Mail's full-swipe animation: the row slides out, the action runs, the row comes back (or leaves, if the action removes it).
    private func perform(_ action: FeedSwipeAction) {
        armed = true
        withAnimation(.cmuxMobileSnappy) { offset = -width }
        Task {
            try? await Task.sleep(for: .milliseconds(220))
            if action.removesRow { action.action() }
            armed = false
            withAnimation(.cmuxMobileSnappy) { offset = 0 }
            if coordinator.openID == id { coordinator.openID = nil }
            guard !action.removesRow else { return }
            try? await Task.sleep(for: .milliseconds(260))
            action.action()
        }
    }

    private func close() {
        withAnimation(.cmuxMobileSnappy) { offset = 0 }
        if coordinator.openID == id { coordinator.openID = nil }
    }

    private func runDemo() {
        if coordinator.demoReveal == id {
            coordinator.openID = id
            withAnimation(.cmuxMobileSnappy) { offset = -revealWidth }
        }
        if let request = coordinator.demoPerform, request.id == id,
           let action = actions.first(where: { $0.id == request.action }) {
            perform(action)
        }
    }
}

/// A pan that begins only for mostly horizontal movement, so the Feed keeps
/// scrolling vertically, and only leftward unless the row is open, so a
/// rightward pan falls through to the team drawer.
struct HorizontalPan: UIGestureRecognizerRepresentable {
    var isOpen: Bool
    var onChange: (CGFloat) -> Void
    var onEnd: (CGFloat, CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        // The team drawer's pan waits for this one: an open row closes first.
        pan.name = RowSwipeActions.panName
        return pan
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.isOpen = isOpen
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .changed: onChange(translation)
        case .ended, .cancelled, .failed: onEnd(translation, recognizer.velocity(in: recognizer.view).x)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isOpen = false

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            guard abs(velocity.x) > abs(velocity.y) * 1.3 else { return false }
            return velocity.x < 0 || isOpen
        }
    }
}

extension FeedItem {
    /// Mail-style trailing actions for this event, outermost (full swipe)
    /// first. At most three: the decision the event asks for, then read state
    /// or Open. Everything else is in the cell's context menu.
    @MainActor
    func swipeActions(store: FeedStore, open: @escaping () -> Void) -> [FeedSwipeAction] {
        let read = isRead
            ? FeedSwipeAction(id: "unread", title: "Unread", systemImage: "envelope.badge", tint: FeedSwipeTint.read) { store.markUnread(id) }
            : FeedSwipeAction(id: "read", title: "Read", systemImage: "envelope.open", tint: FeedSwipeTint.read) { store.markRead(id) }
        let done = FeedSwipeAction(id: "done", title: "Done", systemImage: "checkmark", tint: FeedSwipeTint.archive, removesRow: true) {
            withAnimation(.cmuxMobileSmooth) { store.markDone(id) }
        }
        guard resolution == nil else { return [done, read] }
        switch kind {
        case .permission(let request):
            // A full swipe denies, never allows: granting a permission takes a deliberate tap.
            let allow = request.phoneOptions.first(where: { $0.kind == .allowOnce }) ?? request.phoneOptions.first(where: \.isAllow)
            let deny = request.phoneOptions.first(where: { $0.kind == .rejectOnce }) ?? request.phoneOptions.first(where: { !$0.isAllow })
            var actions: [FeedSwipeAction] = []
            if let deny {
                actions.append(FeedSwipeAction(id: "deny", title: "Deny", systemImage: "xmark.shield", tint: FeedSwipeTint.destructive) {
                    withAnimation(.cmuxMobileSmooth) { store.respond(id, option: deny) }
                })
            }
            if let allow {
                // The allow asks for Face ID before it is sent (verify/phone-approvals.md).
                actions.append(FeedSwipeAction(id: "allow", title: "Allow", systemImage: "faceid", tint: FeedSwipeTint.approve) {
                    withAnimation(.cmuxMobileSmooth) { store.respond(id, option: allow) }
                })
            }
            return actions
        case .question(let question) where question.isPending:
            let answer = FeedSwipeAction(id: "answer", title: "Answer", systemImage: "arrowshape.turn.up.left", tint: FeedSwipeTint.read, action: open)
            let decline = FeedSwipeAction(id: "decline", title: "Decline", systemImage: "xmark", tint: FeedSwipeTint.destructive) {
                withAnimation(.cmuxMobileSmooth) { store.decline(id) }
            }
            return [decline, answer]
        case .needsInput:
            // Answered in the terminal: the decision is opening it.
            let answer = FeedSwipeAction(id: "answer", title: "Open", systemImage: "terminal", tint: FeedSwipeTint.read, action: open)
            return [done, answer]
        default:
            return [done, read]
        }
    }
}
#endif
