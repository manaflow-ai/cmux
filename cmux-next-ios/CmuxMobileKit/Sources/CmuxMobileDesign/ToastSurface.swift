#if os(iOS)
import SwiftUI

extension View {
    /// Makes a toast, banner or undo bar dismissible the same way everywhere: it follows
    /// the finger (up or sideways for one that entered from the top, down or sideways from
    /// the bottom) and springs back, dismisses past a distance or on a flick (`ToastDismissal`),
    /// and dismisses on a tap unless `tapDismisses` is false (a bar with its own button).
    /// VoiceOver announces `announcement` when it appears and offers a Dismiss action.
    public func cmuxMobileDismissibleToast(entry: ToastDismissal.Entry, announcement: String? = nil, tapDismisses: Bool = true,
                                    onDismiss: @escaping () -> Void) -> some View {
        modifier(ToastDismissModifier(rule: ToastDismissal(entry: entry), announcement: announcement,
                                      tapDismisses: tapDismisses, onDismiss: onDismiss))
    }
}

/// Private on purpose (see `ToastHost` in States.swift): a public modifier body would be
/// serialized into client modules by cross-module optimization.
private struct ToastDismissModifier: ViewModifier {
    let rule: ToastDismissal
    let announcement: String?
    let tapDismisses: Bool
    let onDismiss: () -> Void
    @State private var drag: CGSize = .zero
    @State private var size: CGSize = .zero
    @State private var leaving = false

    func body(content: Content) -> some View {
        dragged(content)
            .accessibilityAction(named: Text("Dismiss")) { onDismiss() }
            .onAppear {
                if let announcement { AccessibilityNotification.Announcement(announcement).post() }
            }
    }

    @ViewBuilder
    private func dragged(_ content: Content) -> some View {
        let base = content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .offset(rule.offset(for: drag))
            .opacity(leaving ? 0 : 1 - min(0.6, max(abs(rule.offset(for: drag).width), abs(rule.offset(for: drag).height)) / 200))
            .contentShape(.rect)
            .simultaneousGesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { drag = $0.translation }
                    .onEnded { value in
                        if rule.dismisses(translation: value.translation, predictedEnd: value.predictedEndTranslation) {
                            withAnimation(.spring(duration: 0.25, bounce: 0)) {
                                drag = rule.exitOffset(for: value.translation, size: size)
                                leaving = true
                            }
                            onDismiss()
                        } else {
                            withAnimation(.spring(duration: 0.35, bounce: 0.3)) { drag = .zero }
                        }
                    }
            )
        // A tap dismisses, except on a bar with its own button (Undo keeps its tap).
        if tapDismisses {
            base.onTapGesture { onDismiss() }
        } else {
            base
        }
    }
}
#endif
