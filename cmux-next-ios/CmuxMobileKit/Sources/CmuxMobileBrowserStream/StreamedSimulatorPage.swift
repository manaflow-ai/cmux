#if os(iOS)
import AVFoundation
import CmuxMobileDesign
import SwiftUI
import UIKit

/// A Mac phone tab's simulator, streamed like a browser tab (the same model,
/// media lane and visibility handling): its frames shown whole, every finger
/// on them a touch on the simulator at 0...1 of its screen (taps, drags,
/// scrolls and long presses all are), the keyboard typing into it, and Home,
/// Lock and the keyboard in an accessory bar.
public struct StreamedSimulatorPage: View {
    let model: StreamedBrowserModel
    var insets: EdgeInsets

    public static let unavailableText = String(localized: "Simulators aren't available from this Mac.")

    public init(model: StreamedBrowserModel, insets: EdgeInsets) {
        self.model = model
        self.insets = insets
    }

    public var body: some View {
        ZStack {
            SimulatorSurface(model: model)
                .accessibilityIdentifier("simulator.stream")
            if model.phase == .unavailable {
                retryStatus(Self.unavailableText)
            } else if case let .waiting(reason) = model.phase {
                if model.canReopen {
                    VStack(spacing: 10) {
                        Text(reason).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        RetryButton(action: retry).accessibilityIdentifier("simulator.retry")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .glassEffect(.regular, in: .rect(cornerRadius: 18))
                } else {
                    retryStatus(reason)
                }
            } else if model.phase == .connecting {
                status(String(localized: "Opening the simulator on your Mac…"))
            }
            if StreamedBrowserOverlay.enabled {
                // Top left: the accessory bar (Home, Lock, keyboard) sits at the bottom.
                StreamedBrowserOverlay(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
            }
        }
        .padding(.top, insets.top)
        .padding(.bottom, insets.bottom)
        .background(Color.black)
        .onAppear {
            model.setVisible(true)
            model.reconnect()
        }
        .onDisappear { model.setVisible(false) }
    }

    func retry() async { model.reopen() }

    private func retryStatus(_ text: String) -> some View {
        VStack {
            Text(text).font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            RetryButton(action: retry).accessibilityIdentifier("simulator.retry")
        }
        .padding(.horizontal, 16)
    }

    private func status(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The row above the toolbar on a simulator tab: Home, Lock and the keyboard.
public struct StreamedSimulatorAccessory: View {
    let model: StreamedBrowserModel

    public init(model: StreamedBrowserModel) { self.model = model }

    public var body: some View {
        HStack(spacing: 12) {
            button("Home", "circle", "home") { model.pressButton("home") }
            button("Lock", "lock", "lock") { model.pressButton("lock") }
            button(model.wantsKeyboard ? "Hide Keyboard" : "Keyboard",
                   model.wantsKeyboard ? "keyboard.chevron.compact.down" : "keyboard", "keyboard") {
                model.wantsKeyboard.toggle()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
    }

    private func button(_ title: String, _ symbol: String, _ id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(title)
        .accessibilityIdentifier("simulator.\(id)")
    }
}

struct SimulatorSurface: UIViewRepresentable {
    let model: StreamedBrowserModel

    func makeUIView(context: Context) -> SimulatorStreamView { SimulatorStreamView(model: model) }

    func updateUIView(_ view: SimulatorStreamView, context: Context) {
        if model.wantsKeyboard, !view.isFirstResponder {
            view.becomeFirstResponder()
        } else if !model.wantsKeyboard, view.isFirstResponder {
            view.resignFirstResponder()
        }
    }
}

/// Shows the decoder's layer (aspect fit) and sends each finger on the
/// picture as a simulator touch. Raw touches, not gesture recognizers: the
/// simulator itself tells a tap from a drag, a scroll or a long press.
final class SimulatorStreamView: UIView, UIKeyInput {
    let model: StreamedBrowserModel
    private let video: AVSampleBufferDisplayLayer
    /// The one finger being sent (the simulator takes one touch at a time from here).
    private var finger: UITouch?

    init(model: StreamedBrowserModel) {
        self.model = model
        video = model.decoder.layer
        super.init(frame: .zero)
        backgroundColor = .black
        isMultipleTouchEnabled = false
        video.removeFromSuperlayer()
        layer.addSublayer(video)
        isAccessibilityElement = true
        accessibilityTraits = .allowsDirectInteraction
        accessibilityIdentifier = "simulator.screen"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        video.frame = bounds
        CATransaction.commit()
        model.layout(points: bounds.size, screenScale: Double(window?.screen.scale ?? traitCollection.displayScale))
    }

    /// A point in this view as 0...1 of the simulator's screen (the picture is aspect fit), clamped.
    func normalized(_ point: CGPoint) -> CGPoint {
        StreamedBrowserModel.normalized(point, in: bounds.size,
                                        picture: CGSize(width: Int(model.meter.width), height: Int(model.meter.height)))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard finger == nil, let touch = touches.first else { return }
        finger = touch
        model.touch("down", at: normalized(touch.location(in: self)))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let finger, touches.contains(finger) else { return }
        model.touch("move", at: normalized(finger.location(in: self)))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }

    private func lift(_ touches: Set<UITouch>) {
        guard let finger, touches.contains(finger) else { return }
        self.finger = nil
        model.touch("up", at: normalized(finger.location(in: self)))
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, model.wantsKeyboard { model.wantsKeyboard = false }
        return resigned
    }

    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }

    func insertText(_ text: String) {
        switch text {
        case "\n": key("Enter", key: "Enter", text: "\r")
        case "\t": key("Tab", key: "Tab", text: "\t")
        default: model.input(model.wire.commit(text))
        }
    }

    func deleteBackward() { key("Backspace", key: "Backspace") }

    private func key(_ code: String, key: String, text: String = "") {
        model.input(model.wire.key(code, key: key, text: text, down: true))
        model.input(model.wire.key(code, key: key, text: text, down: false))
    }
}
#endif
