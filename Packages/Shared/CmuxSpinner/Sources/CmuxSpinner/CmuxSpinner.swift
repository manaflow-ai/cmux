public import SwiftUI

/// The spinner in SwiftUI, in place of an indeterminate `ProgressView()`: ``CmuxSpinnerView`` at a
/// side from `size`, or else from the control size (mini 10, small 14, regular 20, large 28 pt), in
/// `tint` (secondary label ink unless set), turning once per the shared spinner period while shown.
/// With a `label`, the label sits under it in secondary ink, as `ProgressView("…")` drew it.
public struct CmuxSpinner: View {
    private let size: CGFloat?
    private let tint: Color?
    private let label: Text?
    @Environment(\.controlSize) private var controlSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cmuxSpinnerDrawsStill) private var still

    /// - Parameters:
    ///   - size: The side in points; nil follows the environment's control size.
    ///   - tint: The arc's ink; nil is secondary label ink. The `.tint(_:)` modifier is not read, so pass it here.
    ///   - label: Words under the spinner (what is loading), or none.
    public init(size: CGFloat? = nil, tint: Color? = nil, label: Text? = nil) {
        self.size = size
        self.tint = tint
        self.label = label
    }

    /// The side a control size gives.
    public static func side(for controlSize: ControlSize) -> CGFloat {
        switch controlSize {
        case .mini: 10
        case .small: 14
        case .large, .extraLarge: 28
        default: 20
        }
    }

    public var body: some View {
        let side = size ?? Self.side(for: controlSize)
        if let label {
            VStack(spacing: 8) {
                arc(side).frame(width: side, height: side).accessibilityHidden(true)
                label.foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        } else {
            arc(side).frame(width: side, height: side)
        }
    }

    /// The turning arc; in a still picture (`ImageRenderer`, which draws a UIKit or AppKit view
    /// as a yellow square with a red sign) the same arc at rest, drawn in SwiftUI.
    @ViewBuilder private func arc(_ side: CGFloat) -> some View {
        if still {
            let line = CmuxSpinnerLayer.lineWidth(side: side)
            Circle()
                .inset(by: line / 2)
                .trim(from: 0, to: CmuxSpinnerLayer.arcLength)
                .stroke(tint ?? Color.secondary, style: StrokeStyle(lineWidth: line, lineCap: .round))
        } else {
            Host(side: side, tint: tint, reduceMotion: reduceMotion)
        }
    }
}

extension EnvironmentValues {
    /// The view is drawn once into a still picture (`ImageRenderer`): a spinner draws its arc at
    /// rest in SwiftUI, not its UIKit or AppKit view, which the picture would show as the system's
    /// cannot-draw mark. Set with the rest of a still picture's environment (`drawnAsStillPicture`).
    @Entry public var cmuxSpinnerDrawsStill = false
}

#if canImport(UIKit)
extension CmuxSpinner {
    private struct Host: UIViewRepresentable {
        let side: CGFloat
        let tint: Color?
        let reduceMotion: Bool

        func makeUIView(context: Context) -> CmuxSpinnerView {
            let view = CmuxSpinnerView(side: side)
            view.startAnimating()
            return view
        }

        func updateUIView(_ view: CmuxSpinnerView, context: Context) {
            view.side = side
            view.reducesMotion = reduceMotion
            view.tintColor = tint.map { UIColor($0) } ?? .secondaryLabel
        }
    }
}
#elseif canImport(AppKit)
extension CmuxSpinner {
    private struct Host: NSViewRepresentable {
        let side: CGFloat
        let tint: Color?
        let reduceMotion: Bool

        func makeNSView(context: Context) -> CmuxSpinnerView {
            let view = CmuxSpinnerView(side: side)
            view.startAnimation()
            return view
        }

        func updateNSView(_ view: CmuxSpinnerView, context: Context) {
            view.side = side
            view.reducesMotion = reduceMotion
            view.tint = tint.map { NSColor($0) } ?? .secondaryLabelColor
        }
    }
}
#endif
