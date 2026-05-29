import Foundation
import AppKit
import QuartzCore
import CoreVideo

/// Animates split view divider positions with display-synced updates and pixel-perfect positioning
@MainActor
final class SplitAnimator {

    // MARK: - Types

    private struct Animation {
        weak var splitView: NSSplitView?
        let startPosition: CGFloat
        let endPosition: CGFloat
        let startTime: CFTimeInterval
        let duration: CFTimeInterval
        var onComplete: (() -> Void)?
    }

    // MARK: - Properties

    nonisolated(unsafe) private var displayLink: CVDisplayLink?
    nonisolated(unsafe) private let tickGate = SplitAnimatorTickGate()
    private var animations: [UUID: Animation] = [:]

    /// Shared animator instance
    static let shared = SplitAnimator()

    /// Default animation duration in seconds
    nonisolated static let defaultAnimationDuration: CFTimeInterval = 0.16
    // MARK: - Initialization

    private init() {
        setupDisplayLink()
    }

    deinit {
        if let displayLink {
            CVDisplayLinkStop(displayLink)
        }
    }

    // MARK: - Display Link

    private func setupDisplayLink() {
        var link: CVDisplayLink?
        let createStatus = CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard createStatus == kCVReturnSuccess else { return }
        guard let link else { return }

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, context in
            let animator = Unmanaged<SplitAnimator>.fromOpaque(context!).takeUnretainedValue()
            guard animator.tickGate.beginFrame() else {
                return kCVReturnSuccess
            }
            Task { @MainActor in
                defer { animator.tickGate.endFrame() }
                animator.tick()
            }
            return kCVReturnSuccess
        }

        CVDisplayLinkSetOutputCallback(link, callback, Unmanaged.passUnretained(self).toOpaque())
        displayLink = link
    }

    // MARK: - Animation Control

    @discardableResult
    func animate(
        splitView: NSSplitView,
        from startPosition: CGFloat,
        to endPosition: CGFloat,
        duration: CFTimeInterval = SplitAnimator.defaultAnimationDuration,
        onComplete: (() -> Void)? = nil
    ) -> UUID {
        let id = UUID()

        splitView.layoutSubtreeIfNeeded()
        splitView.setPosition(round(startPosition), ofDividerAt: 0)
        splitView.layoutSubtreeIfNeeded()

        guard duration > 0, let displayLink else {
            splitView.setPosition(round(endPosition), ofDividerAt: 0)
            splitView.layoutSubtreeIfNeeded()
            onComplete?()
            return id
        }

        animations[id] = Animation(
            splitView: splitView,
            startPosition: startPosition,
            endPosition: endPosition,
            startTime: CACurrentMediaTime(),
            duration: duration,
            onComplete: onComplete
        )

        if !CVDisplayLinkIsRunning(displayLink) {
            let startStatus = CVDisplayLinkStart(displayLink)
            if startStatus != kCVReturnSuccess {
                animations.removeValue(forKey: id)
                splitView.setPosition(round(endPosition), ofDividerAt: 0)
                splitView.layoutSubtreeIfNeeded()
                onComplete?()
            }
        }

        return id
    }

    func cancel(_ id: UUID) {
        animations.removeValue(forKey: id)
        stopIfNeeded()
    }

    // MARK: - Frame Update

    private func tick() {
        let currentTime = CACurrentMediaTime()
        var completedIds: [UUID] = []
        var completions: [() -> Void] = []

        for (id, animation) in animations {
            guard let splitView = animation.splitView else {
                completedIds.append(id)
                if let onComplete = animation.onComplete {
                    completions.append(onComplete)
                }
                continue
            }

            let elapsed = currentTime - animation.startTime
            let progress = min(elapsed / animation.duration, 1.0)
            let eased = progress == 1.0 ? 1.0 : 1.0 - pow(2.0, -10.0 * progress)

            let position = animation.startPosition + (animation.endPosition - animation.startPosition) * eased

            // Round to whole pixels to prevent artifacts
            splitView.setPosition(round(position), ofDividerAt: 0)

            if progress >= 1.0 {
                completedIds.append(id)
                if let onComplete = animation.onComplete {
                    completions.append(onComplete)
                }
            }
        }

        for id in completedIds {
            animations.removeValue(forKey: id)
        }

        stopIfNeeded()

        for completion in completions {
            completion()
        }
    }

    private func stopIfNeeded() {
        if animations.isEmpty, let displayLink, CVDisplayLinkIsRunning(displayLink) {
            CVDisplayLinkStop(displayLink)
        }
    }
}

final class SplitAnimatorTickGate {
    private let lock = NSLock()
    private var framePending = false

    func beginFrame() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !framePending else { return false }
        framePending = true
        return true
    }

    func endFrame() {
        lock.lock()
        framePending = false
        lock.unlock()
    }

    var isFramePendingForTesting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return framePending
    }
}
