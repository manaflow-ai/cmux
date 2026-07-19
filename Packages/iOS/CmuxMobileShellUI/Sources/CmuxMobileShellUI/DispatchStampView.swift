import CmuxMobileSupport
import SwiftUI

/// The rubber-stamp verdict pressed onto the work order's stub: green
/// DISPATCHED on success, red REJECTED on failure. Springs in slightly
/// oversized and rotated, like it was actually stamped.
struct DispatchStampView: View {
    enum Verdict {
        case dispatched
        case rejected
    }

    let verdict: Verdict
    @State private var pressed = false

    private var text: String {
        switch verdict {
        case .dispatched:
            return L10n.string("mobile.dispatch.stamp.dispatched", defaultValue: "DISPATCHED")
        case .rejected:
            return L10n.string("mobile.dispatch.stamp.rejected", defaultValue: "REJECTED")
        }
    }

    private var color: Color {
        switch verdict {
        case .dispatched: return DispatchStyle.stampApproved
        case .rejected: return DispatchStyle.stampRejected
        }
    }

    var body: some View {
        Text(text)
            .font(.system(.body, design: .monospaced).weight(.heavy))
            .tracking(3)
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(color, lineWidth: 2.5)
            )
            .rotationEffect(.degrees(-8))
            .opacity(pressed ? 0.92 : 0)
            .scaleEffect(pressed ? 1 : 1.6)
            .onAppear {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.6)) {
                    pressed = true
                }
            }
            .accessibilityIdentifier("MobileDispatchStamp")
    }
}

/// A ticket tear line: dashed hairline with half-round notches at both edges.
/// Sits between the order's fields and its launch stub.
struct DispatchPerforationDivider: View {
    private let notchRadius: CGFloat = 7

    var body: some View {
        HStack(spacing: 0) {
            notch(cutTrailing: true)
            Line()
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                .foregroundStyle(DispatchStyle.hairline)
                .frame(height: 1)
            notch(cutTrailing: false)
        }
        .frame(height: notchRadius * 2)
        .accessibilityHidden(true)
    }

    private func notch(cutTrailing: Bool) -> some View {
        Circle()
            .fill(DispatchStyle.screenBackground)
            .overlay(
                Circle().stroke(DispatchStyle.hairline, lineWidth: 0.5)
            )
            .frame(width: notchRadius * 2, height: notchRadius * 2)
            .offset(x: cutTrailing ? -notchRadius : notchRadius)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
    }
}
