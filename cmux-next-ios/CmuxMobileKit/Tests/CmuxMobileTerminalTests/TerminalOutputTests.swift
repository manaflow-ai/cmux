import CmuxMobileArtifacts
import CoreGraphics
import Foundation
import Testing
@testable import CmuxMobileTerminal

/// The per-frame output queue: bounded work per frame, order kept,
/// backpressure thresholds (verify/terminal-flood.md).
@Suite struct TerminalOutputQueueTests {
    @Test func manyChunksBecomeOneBatchPerFrame() {
        var queue = TerminalOutputQueue()
        for index in 0..<500 { queue.append(Data("line \(index)\r\n".utf8)) }
        let total = queue.pendingBytes
        guard case .bytes(let batch)? = queue.next(budget: 1 << 20) else { Issue.record("no batch"); return }
        #expect(batch.count == total)
        #expect(String(decoding: batch, as: UTF8.self).hasPrefix("line 0\r\nline 1\r\n"))
        #expect(queue.isEmpty)
        #expect(queue.next() == nil)
    }

    @Test func eachFrameTakesAtMostTheBudgetInOrder() {
        var queue = TerminalOutputQueue()
        var expected = Data()
        for index in 0..<100 {
            let chunk = Data(repeating: UInt8(index), count: 1000)
            expected.append(chunk)
            queue.append(chunk)
        }
        var out = Data()
        var frames = 0
        while case .bytes(let batch)? = queue.next(budget: 4096) {
            #expect(batch.count <= 4096)
            out.append(batch)
            frames += 1
        }
        #expect(out == expected)
        #expect(frames == 25)
        #expect(queue.pendingBytes == 0)
    }

    @Test func alternateScreenSwitchWaitsForTheBytesBeforeIt() {
        var queue = TerminalOutputQueue()
        queue.append(Data("before".utf8))
        queue.append(alternateScreen: true)
        queue.append(Data("after".utf8))
        #expect(queue.next(budget: 3) == .bytes(Data("bef".utf8)))
        #expect(queue.next(budget: 100) == .bytes(Data("ore".utf8)))
        #expect(queue.next() == .alternateScreen(true))
        #expect(queue.next() == .bytes(Data("after".utf8)))
        #expect(queue.next() == nil)
    }

    @Test func highAndLowWater() {
        var queue = TerminalOutputQueue()
        queue.append(Data(count: TerminalOutputQueue.highWater + 1))
        #expect(queue.isOverHighWater)
        #expect(!queue.isUnderLowWater)
        while queue.pendingBytes >= TerminalOutputQueue.lowWater { _ = queue.next() }
        #expect(queue.isUnderLowWater)
    }
}

@Suite struct UserInputTests {
    @Test func onlyWhatThePersonTypedCounts() {
        #expect(TerminalInputAction.text("a").isUserInput)
        #expect(TerminalInputAction.paste("ls\n").isUserInput)
        #expect(!TerminalInputAction.preedit("ka").isUserInput)
        #expect(!TerminalInputAction.text("").isUserInput)
        var router = TerminalInputRouter()
        let actions = router.key(usage: TerminalHIDUsage.up, extra: [])
        #expect(actions.contains { $0.isUserInput })
        #expect(actions.filter(\.isUserInput).count == actions.filter { if case .key(let e) = $0 { e.isPress } else { false } }.count)
    }
}

@Suite struct KeyBarClippingTests {
    @Test func keysWhoseCenterIsUnderThePinnedGroupOrPastTheEndAreHidden() {
        let clipping = KeyBarClipping()
        let visible = CGRect(x: 120, y: 0, width: 200, height: 44) // scrolled by 120
        #expect(clipping.isActivatable(CGRect(x: 130, y: 0, width: 40, height: 34), in: visible))
        // Cut at the leading edge, center showing: a tap at its center hits it.
        #expect(clipping.isActivatable(CGRect(x: 110, y: 0, width: 40, height: 34), in: visible))
        #expect(!clipping.isActivatable(CGRect(x: 90, y: 0, width: 40, height: 34), in: visible)) // under esc/ctrl/alt
        #expect(!clipping.isActivatable(CGRect(x: 310, y: 0, width: 40, height: 34), in: visible)) // under the joystick
        #expect(clipping.isActivatable(CGRect(x: 0, y: 0, width: 40, height: 34), in: nil))
    }
}

@MainActor @Suite struct TerminalArtifactCollectorTests {
    @Test func scansOffTheMainThreadAndPublishesInOrder() async {
        var published: [[TerminalArtifact]] = []
        let collector = TerminalArtifactCollector { published.append($0) }
        collector.scan(Data("open docs/a.md\r\n".utf8))
        collector.scan(Data("see https://example.com/x and src/b.rs\r\nnothing here\r\n".utf8))
        await collector.flush()
        #expect(published.last?.map(\.reference) == ["docs/a.md", "https://example.com/x", "src/b.rs"])
        // A line split across batches is one reference.
        collector.scan(Data("cat lib/c".utf8))
        collector.scan(Data(".swift\r\n".utf8))
        await collector.flush()
        #expect(published.last?.last?.reference == "lib/c.swift")
    }

    @Test func reconcileJoinsAPathTheStreamSawInPieces() async {
        var published: [[TerminalArtifact]] = []
        let collector = TerminalArtifactCollector { published.append($0) }
        collector.scan(Data("cat /live/work/demo/REA\r\nDME.md\r\n".utf8))
        collector.reconcile(screenText: "cat /live/work/demo/README.md\n", columns: nil)
        await collector.flush()
        #expect(published.last?.map(\.reference).contains("/live/work/demo/README.md") == true)
    }
}

/// User report 2026-10-14 (real iPhone): "the scroll isn't smooth when I'm
/// scrolling while ... the agent is outputting stuff". While a finger or a
/// deceleration owns the page, each frame's batch is small enough that
/// Ghostty's parse (under the lock the main thread's viewport request also
/// takes) stays well inside a 120 Hz frame: at most 16 KB.
@Suite struct TerminalOutputBudgetTests {
    @Test func aBatchWhileInteractingIsSmall() {
        #expect(TerminalOutputQueue.budget(interacting: true) <= 16 << 10)
        #expect(TerminalOutputQueue.budget(interacting: false) == TerminalOutputQueue.frameBudget)
        // Throughput stays far above any agent's stream: 16 KB a frame is 1.9 MB/s at 120 Hz.
        var queue = TerminalOutputQueue()
        queue.append(Data(repeating: 0x41, count: 100 << 10))
        guard case .bytes(let first)? = queue.next(budget: TerminalOutputQueue.budget(interacting: true)) else {
            Issue.record("no batch")
            return
        }
        #expect(first.count <= 16 << 10)
    }
}
