import SwiftUI

struct MobileToastIcon: View {
    let toast: MobileToast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appearanceCount = 0

    var body: some View {
        Group {
            if toast.content.isProgress {
                ProgressView()
                    .controlSize(.small)
                    .tint(toast.tone.tint)
            } else {
                Image(systemName: toast.tone.symbolName)
                    .font(.system(size: 13, weight: .bold))
                    .symbolEffect(.bounce, value: appearanceCount)
            }
        }
        .foregroundStyle(toast.tone.tint)
        .frame(width: 30, height: 30)
        .background(toast.tone.tint.opacity(0.16), in: Circle())
        .overlay(Circle().strokeBorder(toast.tone.tint.opacity(0.20), lineWidth: 0.5))
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion, !toast.content.isProgress else { return }
            appearanceCount += 1
        }
    }
}
