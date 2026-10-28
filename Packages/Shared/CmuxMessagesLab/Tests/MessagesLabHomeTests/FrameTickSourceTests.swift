import AppKit
import Testing
@testable import MessagesLabHome

/// FrameTick's frames come from the host's ``FrameTickSource``: CmuxNext passes its
/// FrameScheduler, so the controller makes no display link of its own. Work waits for the source's
/// next frame, runs at its start, and the stream stops on the first frame that finds no work.
@MainActor @Suite struct FrameTickSourceTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    /// A frame source whose frames come only when the test calls ``frame()``.
    @MainActor final class ManualFrames: FrameTickSource {
        @MainActor final class Stream: FrameTickStream {
            let onFrame: @MainActor @Sendable () -> Bool
            private(set) var running = false
            private(set) var starts = 0
            private(set) var restarts = 0
            init(onFrame: @escaping @MainActor @Sendable () -> Bool) { self.onFrame = onFrame }
            func start() {
                starts += 1
                running = true
            }
            func restart() {
                restarts += 1
                running = true
            }
            /// The source dropped the stream without a frame (CmuxNext: its window's scheduler was
            /// invalidated when the window closed).
            func drop() { running = false }
            /// One display frame: a running stream calls back and stops when told to.
            func frame() {
                guard running else { return }
                running = onFrame()
            }
        }

        private(set) var streams: [(view: NSView, stream: Stream)] = []

        func frames(for view: NSView, onFrame: @escaping @MainActor @Sendable () -> Bool) -> any FrameTickStream {
            let stream = Stream(onFrame: onFrame)
            streams.append((view, stream))
            return stream
        }

        func frame() { streams.forEach { $0.stream.frame() } }
    }

    @Test func workWaitsForTheSourcesFrameAndTheStreamStopsWhenNothingWaits() throws {
        let frames = ManualFrames()
        let view = NSView()
        let tick = FrameTick(view: view, source: frames)
        var ran: [String] = []

        tick.next { ran.append("a") }
        tick.next { ran.append("b") }
        #expect(ran.isEmpty, "work waits for the frame's start")
        let stream = try #require(frames.streams.first)
        #expect(frames.streams.count == 1 && stream.view === view, "one stream, for the tick's view")
        #expect(stream.stream.running)

        frames.frame()
        #expect(ran == ["a", "b"])
        #expect(tick.fires == 1)
        #expect(!stream.stream.running, "the frame that leaves no work stops the stream")

        frames.frame()
        #expect(tick.fires == 1, "a stopped stream gets no frames")
    }

    @Test func workPostedInAFrameRunsAtTheNextOneOnTheSameStream() {
        let frames = ManualFrames()
        let tick = FrameTick(view: NSView(), source: frames)
        var ran: [String] = []

        tick.next {
            ran.append("first")
            tick.next { ran.append("second") }
        }
        frames.frame()
        #expect(ran == ["first"], "work posted during a frame waits for the next one")
        #expect(frames.streams.first?.stream.running == true)

        frames.frame()
        #expect(ran == ["first", "second"])
        #expect(frames.streams.first?.stream.running == false)

        tick.next { ran.append("third") }
        #expect(frames.streams.count == 1, "a later frame request starts the same stream again")
        frames.frame()
        #expect(ran.last == "third")
        #expect(tick.fires == 3)
    }

    @Test func waitingWorkRestartsTheStreamWhenTheViewMovesAfterItsSourceDroppedIt() throws {
        let frames = ManualFrames()
        let view = NSView()
        let tick = FrameTick(view: view, source: frames)
        var ran = false

        tick.next { ran = true }
        let stream = try #require(frames.streams.first?.stream)
        stream.drop()
        frames.frame()
        #expect(!ran, "a dropped stream gets no frames, and nothing asked for one again")

        tick.viewDidMoveToWindow()
        #expect(stream.restarts == 1 && stream.running, "the waiting work restarts the stream on the new window")
        frames.frame()
        #expect(ran)
        #expect(!stream.running)

        tick.viewDidMoveToWindow()
        #expect(stream.restarts == 1, "with nothing waiting a move starts no frames")
    }

    @Test func aControllerMovedToAnotherWindowRunsItsWaitingWorkThere() throws {
        let frames = ManualFrames()
        let controller = ChatController(host: HostView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)), wake: NoWake(),
                                        frames: frames)
        func makeWindow() -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                                  backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            return window
        }
        let first = makeWindow()
        let second = makeWindow()
        first.contentView = controller.host
        var ran = false

        controller.nextFrame { ran = true }
        let stream = try #require(frames.streams.first?.stream)
        stream.drop()  // the first window closed: its scheduler dropped the stream without a frame
        second.contentView = controller.host
        #expect(stream.restarts >= 1, "moving to the second window restarts the waiting stream")

        frames.frame()
        #expect(ran, "the held work runs on the second window's next frame")
        second.contentView = nil
    }

    @Test func aControllerInAWindowTakesItsFramesFromTheInjectedSource() {
        let frames = ManualFrames()
        let controller = ChatController(host: HostView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)), wake: NoWake(),
                                        frames: frames)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = controller.host
        var ran = false

        controller.nextFrame { ran = true }
        #expect(!ran, "in a window the work waits for the display frame")
        #expect(frames.streams.count == 1 && frames.streams.first?.view === controller.host)

        frames.frame()
        #expect(ran)
        #expect(controller.frameTick.fires == 1)
        window.contentView = nil
    }
}
