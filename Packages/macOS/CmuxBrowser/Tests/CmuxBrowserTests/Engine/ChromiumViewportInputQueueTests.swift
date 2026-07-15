import Testing
@testable import CmuxBrowser

@Suite struct ChromiumViewportInputQueueTests {
    @Test func pointerUpdatesCoalesceWithoutCrossingOrderedInput() {
        var queue = ChromiumViewportInputQueue()

        queue.enqueue(mouse(type: "mouseMoved", x: 1))
        queue.enqueue(mouse(type: "mouseMoved", x: 2))
        queue.enqueue(.key(parameters: ["type": .string("keyDown")]))
        queue.enqueue(mouse(type: "mouseMoved", x: 3))
        queue.enqueue(mouse(type: "mouseMoved", x: 4))

        #expect(queue.count == 3)
        #expect(queue.commands[0].parameters["x"] == .number(2))
        #expect(queue.commands[1].method == "Input.dispatchKeyEvent")
        #expect(queue.commands[2].parameters["x"] == .number(4))
    }

    @Test func wheelUpdatesAccumulateTheirDeltas() {
        var queue = ChromiumViewportInputQueue()

        queue.enqueue(mouse(type: "mouseWheel", deltaX: 2, deltaY: 3))
        queue.enqueue(mouse(type: "mouseWheel", deltaX: -1, deltaY: 5))

        #expect(queue.count == 1)
        #expect(queue.commands[0].parameters["deltaX"] == .number(1))
        #expect(queue.commands[0].parameters["deltaY"] == .number(8))
    }

    @Test func pendingInputHasAFixedUpperBound() {
        var queue = ChromiumViewportInputQueue()

        for index in 0..<(ChromiumViewportInputQueue.maximumPendingCommands * 2) {
            queue.enqueue(.key(parameters: [
                "type": .string("keyDown"),
                "key": .string(String(index)),
            ]))
        }

        #expect(queue.count == ChromiumViewportInputQueue.maximumPendingCommands)
    }

    private func mouse(
        type: String,
        x: Double = 0,
        deltaX: Double = 0,
        deltaY: Double = 0
    ) -> ChromiumViewportInputCommand {
        .mouse(parameters: [
            "type": .string(type),
            "x": .number(x),
            "deltaX": .number(deltaX),
            "deltaY": .number(deltaY),
        ])
    }
}
