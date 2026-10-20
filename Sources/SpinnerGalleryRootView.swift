#if DEBUG
import AppKit
import SwiftUI

struct SpinnerGalleryRootView: View {
    private let tint = NSColor.secondaryLabelColor
    private let size: CGFloat = 22

    private var specs: [SpinnerSpec] {
        let color = tint
        let dim = size
        return [
            SpinnerSpec(
                title: "GPU spokes (shipping)",
                mechanism: "Core Animation transform.rotation.z, discrete steps. Render server animates on the GPU; 0 main-thread work per frame. Pauses when occluded, off-screen, or Reduce Motion is on. Native macOS spokes look.",
                energy: .low,
                shipping: true,
                makeView: { AnyView(GPUSpinner(style: .macOSSpokes, color: color).frame(width: dim, height: dim)) }
            ),
            SpinnerSpec(
                title: "GPU arc (legacy cmux)",
                mechanism: "Core Animation transform.rotation.z, continuous linear. GPU-composited, 0 main-thread work per frame. Same energy profile as spokes, different look.",
                energy: .low,
                shipping: false,
                makeView: { AnyView(GPUSpinner(style: .arc, color: color).frame(width: dim, height: dim)) }
            ),
            SpinnerSpec(
                title: "NSProgressIndicator (default)",
                mechanism: "AppKit system spinner. Timer-driven; redraws every frame on the CPU on the main thread. Highest energy and competes with UI work on the main run loop.",
                energy: .high,
                shipping: false,
                makeView: { AnyView(NativeSpinner(threaded: false).frame(width: dim, height: dim)) }
            ),
            SpinnerSpec(
                title: "NSProgressIndicator (threaded)",
                mechanism: "Same AppKit spinner with usesThreadedAnimation = true. Per-frame redraw moves off the main thread, but it is still CPU drawing every frame, not GPU.",
                energy: .mediumHigh,
                shipping: false,
                makeView: { AnyView(NativeSpinner(threaded: true).frame(width: dim, height: dim)) }
            ),
            SpinnerSpec(
                title: "SwiftUI ProgressView",
                mechanism: "System indeterminate ProgressView. Bridges to the AppKit spinner under the hood; CPU per-frame redraw managed by the framework.",
                energy: .mediumHigh,
                shipping: false,
                makeView: { AnyView(ProgressView().controlSize(.small).frame(width: dim, height: dim)) }
            ),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    OverlayComparison()
                    ForEach(specs) { spec in
                        SpinnerCard(spec: spec)
                    }
                    footnote
                }
                .padding(14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Indeterminate spinners · energy characteristics")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(12)
    }

    private var footnote: some View {
        Text("Ratings are mechanism-based (GPU transform vs CPU per-frame redraw, main-thread vs off-thread), not live measurements. Confirm with Activity Monitor → Energy or Instruments → Energy Log while this window is frontmost.")
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
    }
}
#endif
