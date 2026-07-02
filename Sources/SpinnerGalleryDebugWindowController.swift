#if DEBUG
import AppKit
import SwiftUI

/// Debug-only spinner comparison window (Debug → Debug Windows → Spinner
/// Gallery…, or the `debug.spinner_gallery.show` socket verb). Strings are
/// English-only by design: the file is `#if DEBUG`, matching the other debug
/// windows.
final class SpinnerGalleryDebugWindowController: ReleasingWindowController {
    static let shared = SpinnerGalleryDebugWindowController()

    override func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Spinner Gallery"
        window.identifier = NSUserInterfaceItemIdentifier("cmux.spinnerGallery")
        window.minSize = NSSize(width: 420, height: 480)
        // Float above the workspace windows so frame-capture screenshots reliably
        // target this window (the debug screenshot picks key/main/largest, and
        // the restored terminal window would otherwise win as main).
        window.level = .floating
        window.center()
        window.contentView = NSHostingView(rootView: SpinnerGalleryRootView())
        return window
    }

    func show() {
        showManagedWindow(activateApplication: true, orderFrontRegardless: true)
        window?.makeKey()
    }
}

private struct SpinnerSpec: Identifiable {
    enum Energy: String {
        case low = "Low"
        case mediumHigh = "Medium–High"
        case high = "High"

        var color: Color {
            switch self {
            case .low: return .green
            case .mediumHigh: return .orange
            case .high: return .red
            }
        }
    }

    let id = UUID()
    let title: String
    let mechanism: String
    let energy: Energy
    let shipping: Bool
    let makeView: () -> AnyView
}

private struct SpinnerGalleryRootView: View {
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

/// Superimposes the GPU spokes spinner (red) directly on the native
/// NSProgressIndicator (grey) at a large size so frame-by-frame screenshots can
/// confirm whether spoke count, size, phase, and cadence match.
private struct OverlayComparison: View {
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

private struct SpinnerCard: View {
    let spec: SpinnerSpec

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                spec.makeView()
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(spec.title)
                        .font(.system(size: 12, weight: .semibold))
                    if spec.shipping {
                        Text("IN SIDEBAR")
                            .font(.system(size: 9, weight: .heavy))
                            .tracking(0.6)
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor))
                    }
                    Spacer()
                    Text(spec.energy.rawValue)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(spec.energy.color)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(spec.energy.color.opacity(0.15)))
                }
                Text(spec.mechanism)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
    }
}

/// AppKit `NSProgressIndicator` wrapped for the gallery comparison.
private struct NativeSpinner: NSViewRepresentable {
    let threaded: Bool
    var controlSize: NSControl.ControlSize = .small

    func makeNSView(context: Context) -> NSProgressIndicator {
        let view = NSProgressIndicator()
        view.style = .spinning
        view.controlSize = controlSize
        view.isIndeterminate = true
        view.isDisplayedWhenStopped = false
        view.usesThreadedAnimation = threaded
        view.startAnimation(nil)
        return view
    }

    func updateNSView(_ view: NSProgressIndicator, context: Context) {
        view.controlSize = controlSize
        view.usesThreadedAnimation = threaded
        view.startAnimation(nil)
    }
}
#endif
