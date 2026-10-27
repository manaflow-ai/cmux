import CmuxNextCompat
import Foundation

/// The app's ``MemoryReleaseTurns``: one release slice per later main run loop pass, in the default
/// mode. AppKit dispatches the events already queued between two slices, and a menu's or a drag's
/// tracking loop runs none.
///
/// It is not a `MainWorkScheduler` background post: once that class's queue ticks, a background post
/// waits for the scheduler's next frame, and a hidden app's next frame is the 100 ms stall frame this
/// pace replaces. Chromium runs its long idle periods the same way when no frame is expected
/// (`third_party/blink/renderer/platform/scheduler/common/idle_helper.cc`).
///
/// ```swift
/// MemoryCoordinator(pressure: pressure, slicer: frameSlicer, turns: MainRunLoopReleaseTurns())
/// ```
public final class MainRunLoopReleaseTurns: MemoryReleaseTurns {
    public init() {}

    public func scheduleTurn(_ turn: @escaping @MainActor () -> Void) {
        MainRunLoopBlock.perform(mode: .defaultMode, turn)
    }
}
