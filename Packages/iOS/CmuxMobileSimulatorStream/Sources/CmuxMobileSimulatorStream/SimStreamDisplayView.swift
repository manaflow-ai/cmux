#if canImport(UIKit)
    import AVFoundation
    import CmuxSimulatorStreamKit
    import CoreMedia
    import UIKit

    /// Hardware-decoded video surface plus raw touch capture.
    ///
    /// Rendering goes straight to an `AVSampleBufferDisplayLayer` whose frames
    /// carry display-immediately attachments, so there is no compositor-side
    /// queue between a decoded frame and the screen. Touches are forwarded raw
    /// (down/move/up with normalized coordinates); the simulator's own UIKit
    /// performs all gesture physics, which is what makes remote scrolling feel
    /// native.
    @MainActor
    public final class SimStreamDisplayView: UIView {
        public var onTouchEvent: ((SimStreamInputEvent) -> Void)?

        private let displayLayer = AVSampleBufferDisplayLayer()
        private var configPixelSize = CGSize.zero
        private var activePointerTouch: UITouch?

        public override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = false
            displayLayer.videoGravity = .resizeAspect
            layer.addSublayer(displayLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("SimStreamDisplayView is code-only")
        }

        public override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            displayLayer.frame = bounds
            CATransaction.commit()
        }

        // MARK: - Rendering

        public func applyConfig(_ config: SimStreamConfig) {
            configPixelSize = CGSize(
                width: CGFloat(config.pixelWidth), height: CGFloat(config.pixelHeight))
            displayLayer.sampleBufferRenderer.flush()
        }

        /// Returns true when the frame was handed to a healthy renderer.
        public func enqueue(_ sampleBuffer: CMSampleBuffer, isKeyframe: Bool) -> Bool {
            let renderer = displayLayer.sampleBufferRenderer
            if renderer.status == .failed {
                renderer.flush()
                return false
            }
            if renderer.requiresFlushToResumeDecoding {
                guard isKeyframe else { return false }
                renderer.flush()
            }
            guard renderer.isReadyForMoreMediaData else { return false }
            renderer.enqueue(sampleBuffer)
            return renderer.status != .failed
        }

        public func resetRenderer() {
            displayLayer.sampleBufferRenderer.flush()
        }

        // MARK: - Touch capture

        public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard activePointerTouch == nil, let touch = touches.first else { return }
            guard let normalized = normalizedPoint(for: touch) else { return }
            activePointerTouch = touch
            emit(.began, normalized, touch)
        }

        public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = activePointerTouch, touches.contains(touch) else { return }
            // Clamp moves that drift outside the video so a drag that leaves
            // the letterbox still tracks to the edge instead of freezing.
            let normalized = clampedNormalizedPoint(for: touch)
            emit(.moved, normalized, touch)
        }

        public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = activePointerTouch, touches.contains(touch) else { return }
            activePointerTouch = nil
            emit(.ended, clampedNormalizedPoint(for: touch), touch)
        }

        public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = activePointerTouch, touches.contains(touch) else { return }
            activePointerTouch = nil
            emit(.cancelled, clampedNormalizedPoint(for: touch), touch)
        }

        private func normalizedPoint(for touch: UITouch) -> CGPoint? {
            SimStreamTouchMapping.normalizedPoint(
                touch.location(in: self), pixelSize: configPixelSize, in: bounds)
        }

        private func clampedNormalizedPoint(for touch: UITouch) -> CGPoint {
            SimStreamTouchMapping.clampedNormalizedPoint(
                touch.location(in: self), pixelSize: configPixelSize, in: bounds) ?? .zero
        }

        private func emit(_ phase: SimStreamTouchPhase, _ point: CGPoint, _ touch: UITouch) {
            onTouchEvent?(
                .touch(
                    phase: phase,
                    pointerID: 0,
                    x: Float(point.x),
                    y: Float(point.y),
                    timestampMicroseconds: UInt64(touch.timestamp * 1_000_000)
                ))
        }
    }

    /// Presenter conformance bridging the engine (any executor) onto the
    /// main-actor view.
    ///
    /// Checked by hand: the only stored property is a weak reference (weak
    /// loads are runtime-thread-safe) and every dereference happens inside
    /// `MainActor.run`.
    public final class SimStreamViewPresenter: SimStreamFramePresenting, @unchecked Sendable {
        /// CoreMedia sample buffers are immutable after creation and the
        /// engine never touches one after handing it over.
        private struct SampleBufferBox: @unchecked Sendable {
            let buffer: CMSampleBuffer
        }

        private weak var view: SimStreamDisplayView?

        public init(view: SimStreamDisplayView) {
            self.view = view
        }

        public func applyConfig(_ config: SimStreamConfig) async {
            await MainActor.run { [weak view] in
                view?.applyConfig(config)
            }
        }

        public func present(
            _ sampleBuffer: sending CMSampleBuffer, sequence: UInt64, isKeyframe: Bool
        ) async -> Bool {
            let box = SampleBufferBox(buffer: sampleBuffer)
            return await MainActor.run { [weak view] in
                view?.enqueue(box.buffer, isKeyframe: isKeyframe) ?? false
            }
        }

        public func reset() async {
            await MainActor.run { [weak view] in
                view?.resetRenderer()
            }
        }
    }
#endif
