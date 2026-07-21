import SwiftUI

/// Chrome shared between the platform host and the overlay: keyboard overlap
/// flows in (so bottom toasts float above the keyboard even though the toast
/// window never hosts it), and the visible card's window-space frame flows
/// out (the passthrough window only captures touches inside it — SwiftUI
/// draws the card without dedicated UIViews, so UIKit hit-testing alone
/// cannot tell the card from empty space).
@MainActor
@Observable
final class ToastHostChrome {
    var keyboardInset: CGFloat = 0
    var interactiveRegion: CGRect?
}

/// The full-screen presentation surface for one ``ToastCenter``: places the
/// visible toast against its edge, runs arrival/departure transitions, plays
/// the haptic, and posts the VoiceOver announcement. Mounted once per host
/// (in the passthrough overlay window on iOS).
struct ToastOverlayRoot: View {
    let center: ToastCenter
    var chrome = ToastHostChrome()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let presented = center.presented {
                ToastPresentationView(presented: presented, center: center, chrome: chrome)
                    .id(presented.toast.id)
                    .frame(maxWidth: 520)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: presented.toast.placement == .top ? .top : .bottom
                    )
                    .padding(.horizontal, 12)
                    .padding(.top, presented.toast.placement == .top ? 6 : 0)
                    .padding(
                        .bottom,
                        presented.toast.placement == .bottom ? 8 + chrome.keyboardInset : 0
                    )
                    .transition(ToastMotion.transition(
                        placement: presented.toast.placement,
                        reduceMotion: reduceMotion
                    ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(ToastMotion.driver(reduceMotion: reduceMotion), value: center.presented?.toast.id)
        .animation(.easeOut(duration: 0.25), value: chrome.keyboardInset)
        .sensoryFeedback(trigger: feedbackKey) { old, new in
            guard let style = new.style else { return nil }
            if old.id != new.id { return style.appearFeedback }
            if old.bump != new.bump { return .impact(weight: .light) }
            return nil
        }
        .onChange(of: announceKey) { _, _ in
            guard let presented = center.presented else { return }
            let toast = presented.toast
            let text = [toast.title, toast.message].compactMap(\.self).joined(separator: ". ")
            AccessibilityNotification.Announcement(text).post()
        }
    }

    private struct FeedbackKey: Equatable {
        var id: UUID?
        var bump: Int
        var style: Toast.Style?
    }

    private var feedbackKey: FeedbackKey {
        FeedbackKey(
            id: center.presented?.toast.id,
            bump: center.presented?.bumpCount ?? 0,
            style: center.presented?.toast.style
        )
    }

    private var announceKey: String? {
        center.presented.map { "\($0.toast.id)-\($0.bumpCount)" }
    }
}

extension Toast.Style {
    var appearFeedback: SensoryFeedback {
        switch self {
        case .info: return .impact(weight: .light, intensity: 0.7)
        case .success: return .success
        case .warning: return .warning
        case .failure: return .error
        }
    }
}

/// One visible toast: wraps the card with interactive drag-to-dismiss
/// (free toward the resting edge, rubber-banded away from it), the coalescing
/// bump pulse, and the interaction hold that pauses auto-dismiss mid-touch.
private struct ToastPresentationView: View {
    let presented: ToastCenter.Presented
    let center: ToastCenter
    let chrome: ToastHostChrome

    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false
    @State private var hasAppeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var toast: Toast { presented.toast }
    /// +1 when dismissal means dragging down (bottom toast), -1 for up (top).
    private var dismissSign: CGFloat { toast.placement == .top ? -1 : 1 }
    private var anchor: UnitPoint { toast.placement == .top ? .top : .bottom }

    var body: some View {
        ToastCardView(
            toast: toast,
            iconBounceTrigger: (hasAppeared ? 1 : 0) + presented.bumpCount,
            dismiss: { center.dismiss(toast.id) }
        )
        .phaseAnimator([false, true], trigger: presented.bumpCount) { view, pulsed in
            view.scaleEffect(!reduceMotion && pulsed ? 1.04 : 1, anchor: anchor)
        } animation: { pulsed in
            pulsed
                ? .spring(response: 0.18, dampingFraction: 0.5)
                : .spring(response: 0.3, dampingFraction: 0.7)
        }
        .scaleEffect(dragScale, anchor: anchor)
        .opacity(dragOpacity)
        .offset(y: dragOffset)
        .gesture(dragGesture)
        // Publish the card's resting frame (window space) so the passthrough
        // window captures touches here and nowhere else. Offset/scale during
        // drag are render-level and deliberately don't move the region.
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            chrome.interactiveRegion = frame
        }
        .onAppear { hasAppeared = true }
        .onDisappear {
            // A departing toast must not wipe the region its successor just
            // published; only the last card out turns off capture.
            if center.presented == nil {
                chrome.interactiveRegion = nil
            }
        }
    }

    /// 0 at rest → 1 once the card has travelled far enough to dismiss.
    private var dragProgress: CGFloat {
        min(1, max(0, dragOffset * dismissSign) / 96)
    }

    private var dragScale: CGFloat {
        reduceMotion ? 1 : 1 - 0.04 * dragProgress
    }

    private var dragOpacity: CGFloat {
        1 - 0.25 * dragProgress
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    center.beginInteraction(for: toast.id)
                }
                dragOffset = damped(value.translation.height)
            }
            .onEnded { value in
                isDragging = false
                center.endInteraction(for: toast.id)
                let travel = value.translation.height * dismissSign
                let projected = value.predictedEndTranslation.height * dismissSign
                if projected > 56 || travel > 48 {
                    // Leave dragOffset in place: the removal transition takes
                    // over from the card's current displaced position.
                    center.dismiss(toast.id)
                } else {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) {
                        dragOffset = 0
                    }
                }
            }
    }

    /// Free movement toward the dismiss edge; a firm rubber band away from it
    /// (asymptote 28pt) so the card feels pinned to its edge.
    private func damped(_ translation: CGFloat) -> CGFloat {
        let toward = translation * dismissSign
        if toward >= 0 { return translation }
        let resisted = 28 * (1 - 1 / (1 + (-toward) / 28))
        return -resisted * dismissSign
    }
}
