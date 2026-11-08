#if DEBUG
import AppKit
import SwiftUI

/// Superimposes the GPU spokes spinner (red) directly on the native
/// NSProgressIndicator (grey) at a large size so frame-by-frame screenshots can
/// confirm whether spoke count, size, phase, and cadence match.
struct OverlayComparison: View {
    // Well box; the spinners inside are drawn at the native spinner's intrinsic
    // regular size so the overlay is size-fair (NSProgressIndicator ignores its
    // frame and always draws at this intrinsic size).
    private let dim: CGFloat = 72
    private let nativeBox: CGFloat = 32

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("OVERLAY · native (grey) + GPU spokes (red)")
                .font(.system(size: 11, weight: .heavy))
                .tracking(0.6)
                .foregroundColor(.primary.opacity(0.9))
            HStack(spacing: 20) {
                // Size-matched: native at its intrinsic regular size, GPU framed
                // to the same box, both centered, so the red spokes should land
                // on the grey ones if count/size/phase match.
                overlayWell(label: "superimposed (≈\(Int(nativeBox))pt)") {
                    ZStack {
                        NativeSpinner(threaded: false, controlSize: .regular)
                        GPUSpinner(style: .macOSSpokes, color: NSColor.systemRed.withAlphaComponent(0.7))
                            .frame(width: nativeBox, height: nativeBox)
                    }
                    .frame(width: nativeBox, height: nativeBox)
                }
                overlayWell(label: "native only") {
                    NativeSpinner(threaded: false, controlSize: .regular)
                        .frame(width: nativeBox, height: nativeBox)
                }
                overlayWell(label: "GPU only (\(Int(nativeBox))pt)") {
                    GPUSpinner(style: .macOSSpokes, color: .secondaryLabelColor)
                        .frame(width: nativeBox, height: nativeBox)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    @ViewBuilder
    private func overlayWell<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                // Centering crosshair to judge alignment.
                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: dim)
                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: dim, height: 1)
                content()
            }
            .frame(width: dim + 16, height: dim + 16)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }
}
#endif
