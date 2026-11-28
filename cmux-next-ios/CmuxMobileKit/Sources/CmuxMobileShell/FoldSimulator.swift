#if os(iOS) && DEBUG
import CmuxMobileDesign
import SwiftUI

/// DEBUG only. Launch with `-cmux-mobile-fold-sim` to fold and unfold the app
/// inside one simulator window. The fleet's simulators have no foldable iPhone
/// (cmux `.github/ios-review-gate-devices.json`), so this runs on an iPad mini
/// and frames the app at each size in turn, resizing it live between them as a
/// fold does: the app sees its window change size in place, with no relaunch
/// and no rotation.
///
/// Sizes come from `CMUX_MOBILE_FOLD_SIM_SIZES` (comma-separated `WxH` in
/// points, or `full` for the whole window), default `466x678,full`: the
/// foldable's outer screen (cmux-tui `emulated-devices.json`, "iPhone Duo")
/// and the iPad mini's 744 x 1133 window in place of the unfolded one.
/// `debug.fold.step` (a small button at the top trailing corner) moves to the
/// next size; with `CMUX_MOBILE_FOLD_SIM_INTERVAL=S`, the first tap also starts
/// stepping on its own every S seconds, so a UI test can scroll while the
/// window resizes.
/// `debug.fold.state` reads `step N WxH`. Design: cmuxterm-hq
/// `docs/design/ios-foldable.md`.
public struct FoldSimulatorFrame<Content: View>: View {
    public static var isRequested: Bool { CommandLine.arguments.contains("-cmux-mobile-fold-sim") }

    private let content: Content
    private let sizes: [CGSize?]
    private let interval: Double?
    @State private var step = 0
    @State private var stepping = false

    public init(environment: [String: String] = ProcessInfo.processInfo.environment, @ViewBuilder content: () -> Content) {
        self.content = content()
        let parsed = Self.sizes(environment["CMUX_MOBILE_FOLD_SIM_SIZES"] ?? "466x678,full")
        sizes = parsed.isEmpty ? [CGSize(width: 466, height: 678), nil] : parsed
        interval = environment["CMUX_MOBILE_FOLD_SIM_INTERVAL"].flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil }
    }

    public var body: some View {
        GeometryReader { window in
            let full = CGSize(width: window.size.width + window.safeAreaInsets.leading + window.safeAreaInsets.trailing,
                              height: window.size.height + window.safeAreaInsets.top + window.safeAreaInsets.bottom)
            let size = frameSize(in: full)
            ZStack {
                Color.gray.opacity(0.25)
                content
                    .environment(\.horizontalSizeClass, size.width < 600 ? .compact : .regular)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: size == full ? 0 : 28, style: .continuous))
            }
            .frame(width: full.width, height: full.height)
            .ignoresSafeArea()
            // The resize is animated, so the app lays out at every size in between, as it does mid-fold;
            // with Reduce Motion on it lands in one frame.
            .animation(.smooth(duration: 0.6).unlessReduceMotion, value: step)
            // Below the status bar and off the centered regular-width tab bar: a tap in the
            // status bar's strip never reaches the app on iPad.
            .overlay(alignment: .topTrailing) {
                controls(size).padding(.top, max(window.safeAreaInsets.top, 24) + 4).padding(.trailing, 12)
            }
        }
        .ignoresSafeArea()
        .task(id: stepping) {
            guard stepping, let interval else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                step += 1
            }
        }
    }

    private func frameSize(in full: CGSize) -> CGSize {
        guard let size = sizes[step % sizes.count] else { return full }
        return CGSize(width: min(size.width, full.width), height: min(size.height, full.height))
    }

    private func controls(_ size: CGSize) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: "step \(step) \(Int(size.width))x\(Int(size.height))")
                .font(.caption2.monospaced())
                .accessibilityIdentifier("debug.fold.state")
            Button("Fold step") {
                step += 1
                stepping = interval != nil
            }
                .font(.caption2)
                .accessibilityIdentifier("debug.fold.step")
        }
        .padding(.horizontal, 8)
        .background(.thinMaterial, in: Capsule())
        .opacity(0.8)
    }

    static func sizes(_ spec: String) -> [CGSize?] {
        spec.split(separator: ",").compactMap { part in
            let part = part.trimmingCharacters(in: .whitespaces).lowercased()
            if part == "full" { return .some(nil) }
            let sides = part.split(separator: "x").compactMap { Double($0) }
            guard sides.count == 2, sides[0] > 0, sides[1] > 0 else { return nil }
            return CGSize(width: sides[0], height: sides[1])
        }
    }
}
#endif
