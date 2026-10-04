#if DEBUG
import AppKit
import CmuxNextSettings
import CmuxNextTabs

/// `debug.hover_sweep` (R131): the pointer moves across the focused pane's
/// tabs (`tabs`: indices, default 0,1,2,1,0) through the strip's real
/// hover path. After the first card shows, each retarget's synchronous
/// main-thread time, the target the card shows after it and the
/// display-link frame intervals over the sweep (a missed frame is an
/// interval longer than 1.5 refresh periods) are returned.
@MainActor
enum DebugHoverSweep {
    private static let frames = BenchFrames()

    static func run(_ params: [String: JSONValue], services: AppServices) async -> JSONValue {
        guard let controller = services.windows.active ?? services.windows.controllers.first,
              let strip = controller.content?.focusedPane?.view.stripView, let window = strip.window else {
            return .object(["error": .string("no focused pane with a tab strip")])
        }
        let indices = params["tabs"]?.arrayValue?.compactMap(\.intValue) ?? [0, 1, 2, 1, 0]
        guard let first = indices.first else { return .object(["error": .string("no tabs")]) }
        let coordinator = services.hoverCards
        let saved = (coordinator.pointerLocation, coordinator.windowNumberAt, coordinator.appIsActive)
        defer { (coordinator.pointerLocation, coordinator.windowNumberAt, coordinator.appIsActive) = saved }
        coordinator.windowNumberAt = { _ in window.windowNumber }
        coordinator.appIsActive = { true }
        func move(to index: Int) -> Bool {
            guard let point = TabStripDebug.tabCenter(in: strip, at: index) else { return false }
            let screen = window.convertPoint(toScreen: strip.convert(point, to: nil))
            coordinator.pointerLocation = { screen }
            TabStripDebug.pointerMoved(in: strip, to: point)
            return true
        }
        frames.start()
        guard move(to: first) else {
            _ = frames.stop()
            return .object(["error": .string("no tab \(first)")])
        }
        let shownAfter = await frames.settled(until: { coordinator.machine.shownTarget != nil }, start: .now, window: 50, deadline: 4_000)
        var retargets: [JSONValue] = []
        for index in indices.dropFirst() {
            let start = ContinuousClock.now
            let moved = move(to: index)
            let ms = BenchSpans.ms(.now - start)
            retargets.append(.object([
                "tab": .number(Double(index)), "moved": .bool(moved), "ms": .number((ms * 100).rounded() / 100),
                "shown": .string(coordinator.machine.shownTarget?.id.rawValue ?? ""),
            ]))
            _ = await frames.settled(until: { true }, start: .now, window: 50, deadline: 500)
        }
        let stats = frames.stop()
        let times = retargets.compactMap { $0.objectValue?["ms"]?.doubleValue }
        return .object([
            "first_show_ms": shownAfter.map { .number($0) } ?? .null,
            "retargets": .array(retargets),
            "max_retarget_ms": .number(times.max() ?? 0),
            "frames": stats,
        ])
    }
}
#endif
