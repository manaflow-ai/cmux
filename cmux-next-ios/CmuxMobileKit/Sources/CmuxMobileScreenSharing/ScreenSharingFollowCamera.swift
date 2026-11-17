#if os(iOS)
import CmuxMobileLinkFFI
public import CmuxScreenKit
public import Foundation
import Observation
public import QuartzCore
public import UIKit

/// Follow mode for one shared screen (stub: follows nothing yet).
@MainActor @Observable
public final class ScreenSharingFollowCamera: ScreenCamera {
    public private(set) var isAvailable = false
    public private(set) var isFollowing = false
    public private(set) var isHeld = false

    public init(reduceMotion: @escaping () -> Bool = { UIAccessibility.isReduceMotionEnabled },
                now: @escaping () -> CFTimeInterval = CACurrentMediaTime) {}

    public func attach(to session: ScreenSession) {
        session.camera = self
        session.onFocus = { [weak self] message in self?.receive(message) }
    }

    func receive(_ message: Data) {}

    public func crop(at time: CFTimeInterval, aspect: CGFloat) -> CGRect? { nil }
    public func personMoved(_ visible: CGRect) {}
    public func personTapped() -> Bool { false }
    public func toggle() {}

    nonisolated static func crop(widthShare: Double, viewAspect: Double, source: CGSize) -> (aspect: Double, zoom: Double) {
        (1, 1)
    }
}
#endif
