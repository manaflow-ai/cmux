import CmuxNextWakeups
import Foundation
import QuartzCore
import Testing

/// FRAME OWNER REFACTOR S7: a window's frame tick runs its input clients first, then its other frame clients (springs,
/// probes), as Chrome runs a frame's input before its animation. A live-resize drag that waited for the tick resizes
/// the window in an input client, so the layout's springs and the motion trace of the same tick read the window's new
/// size, in one transaction. The clients used to tick in the order of a Dictionary of ObjectIdentifier keys: an input
/// client could run after the springs, and the tick laid the screen out twice.
@MainActor @Suite(.timeLimit(.minutes(1))) struct FrameSchedulerInputFirstTests {
    @MainActor
    private final class Link: FrameLink {
        var isPaused = false
        func invalidate() {}
    }

    @MainActor
    private final class Media {
        var now: CFTimeInterval = 500
        var read: @MainActor () -> CFTimeInterval { { [self] in self.now } }
    }

    @Test func inputClientsTickBeforeEveryOtherFrameClient() {
        let media = Media()
        let scheduler = FrameScheduler.testing(mediaTime: media.read) { _ in Link() }
        var order: [String] = []
        // Many frame clients, made and activated before the input clients: no hash order can put both inputs first.
        let frames = (0..<12).map { index in
            FrameClient(owner: "frame\(index)", on: scheduler) { _ in
                order.append("frame")
                return true
            }
        }
        let inputs = (0..<2).map { index in
            FrameClient(owner: "input\(index)", isAnimation: false, input: true, on: scheduler) { _ in
                order.append("input")
                return true
            }
        }
        for client in frames { client.activate() }
        for client in inputs { client.activate() }
        defer { (frames + inputs).forEach { $0.deactivate() } }
        for frame in 1...4 {
            order.removeAll()
            media.now += 1.0 / 120
            scheduler.frameDidFire(timestamp: media.now, refreshInterval: 1.0 / 120)
            #expect(order.count == 14, "frame \(frame): \(order)")
            #expect(Array(order.prefix(2)) == ["input", "input"], "frame \(frame): the input clients ran at \(order.indices.filter { order[$0] == "input" })")
        }
    }

    /// An input client is frame work, never a budgeted batch: it ticks every frame, also on a scheduler with no budget.
    @Test func anInputClientTicksEveryFrame() {
        let media = Media()
        let scheduler = FrameScheduler.testing(mediaTime: media.read) { _ in Link() }
        var ticks = 0
        let input = FrameClient(owner: "input", isAnimation: false, input: true, on: scheduler) { _ in
            ticks += 1
            return ticks < 3
        }
        input.activate()
        for _ in 1...5 {
            media.now += 1.0 / 120
            scheduler.frameDidFire(timestamp: media.now, refreshInterval: 1.0 / 120)
        }
        #expect(ticks == 3)
        #expect(!input.isActive)
        #expect(input.workClass == .input)
    }
}
