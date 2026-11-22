#if os(iOS)
import AVFoundation
import CmuxMobileDesign
public import SwiftUI
import UIKit

private let theme = CmuxMobileTheme.standard

/// The full-screen viewer of a cmux.rd/1 session (a Linux desktop, a joined Mac): the picture
/// fitted to the screen, Direct Touch input (tap clicks, one finger drags with the button
/// held, two fingers scroll), a keyboard, and Close. View Only sends nothing.
public struct ScreenSharingRdView: View {
    let session: ScreenSharingRdSession
    let hostName: String
    let close: () -> Void
    @State private var typing = false

    public init(session: ScreenSharingRdSession, hostName: String, close: @escaping () -> Void) {
        self.session = session
        self.hostName = hostName
        self.close = close
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RdSurface(session: session, typing: $typing)
                .ignoresSafeArea(edges: .bottom)
                .accessibilityLabel(Text("\(hostName) screen"))
            if session.phase == .connecting {
                ProgressView()
                    .tint(.white)
                    .accessibilityLabel(Text("Connecting to \(hostName)"))
            }
            if case let .ended(reason) = session.phase {
                Text(reason)
                    .foregroundStyle(.white)
                    .padding()
            }
        }
        .safeAreaInset(edge: .top) {
            HStack(spacing: 12) {
                Button("Close", action: close)
                    .buttonStyle(.cmuxPressFill)
                Spacer()
                if let path = session.path {
                    Text(Self.pathLabel(path, latency: session.latencyMs))
                        .font(theme.type.meta)
                        .foregroundStyle(theme.colors.label2)
                }
                if session.control {
                    Button {
                        typing.toggle()
                    } label: {
                        Image(systemName: "keyboard")
                    }
                    .buttonStyle(.cmuxPressFill)
                    .accessibilityLabel(Text(typing ? "Hide Keyboard" : "Show Keyboard"))
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    static func pathLabel(_ kind: String, latency: Double?) -> String {
        let name = switch kind {
        case "direct_lan": String(localized: "Direct")
        case "direct_wan": String(localized: "Direct (internet)")
        case "turn_relay", "do_relay", "via_cloud_region": String(localized: "Relay")
        default: kind
        }
        guard let latency else { return name }
        return "\(name) · \(Int(latency.rounded())) ms"
    }
}

/// The decoder's layer, with the touches and the keyboard.
private struct RdSurface: UIViewRepresentable {
    let session: ScreenSharingRdSession
    @Binding var typing: Bool

    func makeUIView(context: Context) -> RdSurfaceView {
        let view = RdSurfaceView(session: session)
        return view
    }

    func updateUIView(_ view: RdSurfaceView, context: Context) {
        view.frameSize = session.frameSize
        if typing, !view.isFirstResponder {
            view.becomeFirstResponder()
        } else if !typing, view.isFirstResponder {
            view.resignFirstResponder()
        }
    }
}

final class RdSurfaceView: UIView, UIKeyInput {
    private let session: ScreenSharingRdSession
    private let videoLayer: AVSampleBufferDisplayLayer
    /// The stream's size in pixels (to map touches); zero before the host's welcome.
    var frameSize: CGSize = .zero
    private var lastPan: CGPoint = .zero

    init(session: ScreenSharingRdSession) {
        self.session = session
        videoLayer = session.decoder.layer
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(videoLayer)
        isMultipleTouchEnabled = true
        guard session.control else { return }
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        drag.maximumNumberOfTouches = 1
        addGestureRecognizer(drag)
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        addGestureRecognizer(scroll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        videoLayer.frame = bounds
    }

    /// Where the fitted picture is drawn (`resizeAspect`).
    private var pictureRect: CGRect {
        guard frameSize.width > 0, frameSize.height > 0 else { return bounds }
        return AVMakeRect(aspectRatio: frameSize, insideRect: bounds)
    }

    /// A point in this view as stream pixels, nil outside the picture.
    private func streamPoint(_ point: CGPoint) -> CGPoint? {
        let rect = pictureRect
        guard rect.contains(point), frameSize.width > 0 else { return nil }
        return CGPoint(x: (point.x - rect.minX) / rect.width * frameSize.width,
                       y: (point.y - rect.minY) / rect.height * frameSize.height)
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard let point = streamPoint(gesture.location(in: self)) else { return }
        session.click(at: point)
    }

    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        guard let point = streamPoint(gesture.location(in: self)) else {
            if gesture.state == .ended || gesture.state == .cancelled { session.press(false) }
            return
        }
        switch gesture.state {
        case .began:
            session.movePointer(to: point)
            session.press(true)
        case .changed:
            session.movePointer(to: point)
        default:
            session.movePointer(to: point)
            session.press(false)
        }
    }

    @objc private func scrolled(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        if gesture.state == .began { lastPan = .zero }
        let scale = pictureRect.width > 0 ? frameSize.width / pictureRect.width : 1
        // Content follows the fingers (natural scrolling): fingers up scrolls down.
        session.scroll(dx: -(translation.x - lastPan.x) * scale, dy: -(translation.y - lastPan.y) * scale)
        lastPan = translation
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { session.control }
    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none

    func insertText(_ text: String) {
        if text == "\n" { session.tapKey(usage: 0x28) } else { session.type(text) }
    }

    func deleteBackward() {
        session.tapKey(usage: 0x2A)
    }
}
#endif
