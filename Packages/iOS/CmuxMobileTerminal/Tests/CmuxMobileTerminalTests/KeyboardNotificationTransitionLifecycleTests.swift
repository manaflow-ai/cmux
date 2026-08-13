#if canImport(UIKit) && DEBUG
import CMUXMobileCore
import Foundation
import Testing
import UIKit

@testable import CmuxMobileTerminal

@MainActor
@Suite("Keyboard notification transition lifecycle", .serialized)
struct KeyboardNotificationTransitionLifecycleTests {
    private final class Delegate: NSObject, GhosttySurfaceViewDelegate {
        func ghosttySurfaceView(
            _ surfaceView: GhosttySurfaceView,
            didProduceInput data: Data
        ) {}

        func ghosttySurfaceView(
            _ surfaceView: GhosttySurfaceView,
            didResize size: TerminalGridSize,
            reportID: UInt64
        ) {}
    }

    @Test("stale hide completion cannot override a newer keyboard rise")
    func staleHideCompletionDoesNotReplaceNewerShowTarget() throws {
        let forceWorkaroundKey = "CMUX_UITEST_FORCE_IOS27_KEYBOARD_DOCK"
        let priorValue = ProcessInfo.processInfo.environment[forceWorkaroundKey]
        setenv(forceWorkaroundKey, "1", 1)
        defer {
            if let priorValue {
                setenv(forceWorkaroundKey, priorValue, 1)
            } else {
                unsetenv(forceWorkaroundKey)
            }
        }

        let runtime = try GhosttyRuntime.shared()
        let delegate = Delegate()
        let view = GhosttySurfaceView(runtime: runtime, delegate: delegate)
        view.autoFocusOnWindowAttach = false
        view.isRenderDispatchSuppressed = true
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        view.frame = window.bounds
        window.addSubview(view)
        window.isHidden = false
        view.layoutIfNeeded()
        defer {
            view.prepareForDismantle()
            view.removeFromSuperview()
            window.isHidden = true
        }

        let shownFrame = CGRect(x: 0, y: 574, width: 402, height: 300)
        let hiddenFrame = CGRect(x: 0, y: 874, width: 402, height: 300)
        let interruptedFrame = CGRect(x: 0, y: 720, width: 402, height: 300)

        postKeyboardFrameChange(
            UIResponder.keyboardWillChangeFrameNotification,
            beginFrame: shownFrame,
            endFrame: hiddenFrame
        )
        postKeyboardFrameChange(
            UIResponder.keyboardWillChangeFrameNotification,
            beginFrame: interruptedFrame,
            endFrame: shownFrame
        )
        postKeyboardFrameChange(
            UIResponder.keyboardDidChangeFrameNotification,
            beginFrame: shownFrame,
            endFrame: hiddenFrame
        )

        let probe = probeValues(view.composerDockProbeValue)
        #expect(probe["keyboardDockSource"] == "notification")
        #expect(probe["keyboardTransitionTarget"] == "300.000")
        #expect(probe["keyboardUp"] == "1")
    }

    @Test("a notification seen while detached converges after reattach")
    func detachedWillDoesNotConsumeTheFirstAttachedDid() throws {
        let forceWorkaroundKey = "CMUX_UITEST_FORCE_IOS27_KEYBOARD_DOCK"
        let priorValue = ProcessInfo.processInfo.environment[forceWorkaroundKey]
        setenv(forceWorkaroundKey, "1", 1)
        defer {
            if let priorValue {
                setenv(forceWorkaroundKey, priorValue, 1)
            } else {
                unsetenv(forceWorkaroundKey)
            }
        }

        let runtime = try GhosttyRuntime.shared()
        let delegate = Delegate()
        let view = GhosttySurfaceView(runtime: runtime, delegate: delegate)
        view.autoFocusOnWindowAttach = false
        view.isRenderDispatchSuppressed = true
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let shownFrame = CGRect(x: 0, y: 574, width: 402, height: 300)
        let hiddenFrame = CGRect(x: 0, y: 874, width: 402, height: 300)

        // The observer is registered before attachment, as it is for a SwiftUI
        // representable during a transient host move. This event must not become
        // a remembered leg in a coordinate space that does not exist yet.
        postKeyboardFrameChange(
            UIResponder.keyboardWillChangeFrameNotification,
            beginFrame: shownFrame,
            endFrame: hiddenFrame
        )

        view.frame = window.bounds
        window.addSubview(view)
        window.isHidden = false
        view.layoutIfNeeded()
        defer {
            view.prepareForDismantle()
            view.removeFromSuperview()
            window.isHidden = true
        }

        postKeyboardFrameChange(
            UIResponder.keyboardDidChangeFrameNotification,
            beginFrame: shownFrame,
            endFrame: shownFrame
        )

        let probe = probeValues(view.composerDockProbeValue)
        #expect(probe["keyboardDockSource"] == "notification")
        #expect(probe["keyboardTransitionTarget"] == "300.000")
        #expect(probe["keyboardUp"] == "1")
    }

    @Test("a delayed duplicate will cannot replace the active reversal")
    func delayedDuplicateWillDoesNotReplaceActiveReversal() throws {
        let forceWorkaroundKey = "CMUX_UITEST_FORCE_IOS27_KEYBOARD_DOCK"
        let priorValue = ProcessInfo.processInfo.environment[forceWorkaroundKey]
        setenv(forceWorkaroundKey, "1", 1)
        defer {
            if let priorValue {
                setenv(forceWorkaroundKey, priorValue, 1)
            } else {
                unsetenv(forceWorkaroundKey)
            }
        }

        let runtime = try GhosttyRuntime.shared()
        let delegate = Delegate()
        let view = GhosttySurfaceView(runtime: runtime, delegate: delegate)
        view.autoFocusOnWindowAttach = false
        view.isRenderDispatchSuppressed = true
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        view.frame = window.bounds
        window.addSubview(view)
        window.isHidden = false
        view.layoutIfNeeded()
        defer {
            view.prepareForDismantle()
            view.removeFromSuperview()
            window.isHidden = true
        }

        let shownFrame = CGRect(x: 0, y: 574, width: 402, height: 300)
        let hiddenFrame = CGRect(x: 0, y: 874, width: 402, height: 300)
        let interruptedFrame = CGRect(x: 0, y: 720, width: 402, height: 300)

        postKeyboardFrameChange(
            UIResponder.keyboardWillChangeFrameNotification,
            beginFrame: shownFrame,
            endFrame: hiddenFrame
        )
        postKeyboardFrameChange(
            UIResponder.keyboardWillChangeFrameNotification,
            beginFrame: interruptedFrame,
            endFrame: shownFrame
        )

        // UIKit can deliver a duplicate of the superseded hide leg after the
        // reversal starts. That older will must not reclaim the dock target.
        postKeyboardFrameChange(
            UIResponder.keyboardWillChangeFrameNotification,
            beginFrame: shownFrame,
            endFrame: hiddenFrame
        )

        let probe = probeValues(view.composerDockProbeValue)
        #expect(probe["keyboardDockSource"] == "notification")
        #expect(probe["keyboardTransitionTarget"] == "300.000")
        #expect(probe["keyboardUp"] == "1")
    }

    @Test("matching raw frames re-resolve overlap after the owner resizes")
    func ownerResizeUsesSettledCoordinateSpace() throws {
        let forceWorkaroundKey = "CMUX_UITEST_FORCE_IOS27_KEYBOARD_DOCK"
        let priorValue = ProcessInfo.processInfo.environment[forceWorkaroundKey]
        setenv(forceWorkaroundKey, "1", 1)
        defer {
            if let priorValue {
                setenv(forceWorkaroundKey, priorValue, 1)
            } else {
                unsetenv(forceWorkaroundKey)
            }
        }

        let runtime = try GhosttyRuntime.shared()
        let delegate = Delegate()
        let view = GhosttySurfaceView(runtime: runtime, delegate: delegate)
        view.autoFocusOnWindowAttach = false
        view.isRenderDispatchSuppressed = true
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        view.frame = window.bounds
        window.addSubview(view)
        window.isHidden = false
        view.layoutIfNeeded()
        defer {
            view.prepareForDismantle()
            view.removeFromSuperview()
            window.isHidden = true
        }

        let hiddenFrame = CGRect(x: 0, y: 874, width: 402, height: 300)
        let shownFrame = CGRect(x: 0, y: 574, width: 402, height: 300)
        postKeyboardFrameChange(
            UIResponder.keyboardWillChangeFrameNotification,
            beginFrame: hiddenFrame,
            endFrame: shownFrame
        )
        #expect(probeValues(view.composerDockProbeValue)["keyboardTransitionTarget"] == "300.000")

        // Keep UIKit's raw frame pair unchanged, but move the owner boundary
        // below the keyboard. The completion must settle using this new
        // coordinate space instead of trusting the will-time overlap.
        view.frame = CGRect(x: 0, y: 0, width: 402, height: 900)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        postKeyboardFrameChange(
            UIResponder.keyboardDidChangeFrameNotification,
            beginFrame: hiddenFrame,
            endFrame: shownFrame
        )

        let probe = probeValues(view.composerDockProbeValue)
        #expect(probe["keyboardTransitionTarget"] == "0.000")
        #expect(probe["keyboardUp"] == "1")
    }

    private func postKeyboardFrameChange(
        _ name: Notification.Name,
        beginFrame: CGRect,
        endFrame: CGRect
    ) {
        NotificationCenter.default.post(
            name: name,
            object: nil,
            userInfo: [
                UIResponder.keyboardFrameBeginUserInfoKey: beginFrame,
                UIResponder.keyboardFrameEndUserInfoKey: endFrame,
                UIResponder.keyboardAnimationDurationUserInfoKey: 0.35,
                UIResponder.keyboardAnimationCurveUserInfoKey:
                    UIView.AnimationCurve.easeInOut.rawValue,
            ]
        )
    }

    private func probeValues(_ value: String) -> [String: String] {
        Dictionary(value.split(separator: ";").compactMap { field in
            let parts = field.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return (parts[0], parts[1])
        }, uniquingKeysWith: { _, latest in latest })
    }
}
#endif
