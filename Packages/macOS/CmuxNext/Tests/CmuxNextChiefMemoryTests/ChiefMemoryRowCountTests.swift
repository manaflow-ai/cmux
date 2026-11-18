import AppKit
@testable import CmuxNextChiefMemory
import CmuxNextDesign
import Foundation
import SwiftUI
import Testing

/// A brain whose view has `count` lines, `rc<count>-<i>`, oldest first.
private nonisolated struct ManyLines: ChiefMemorySource {
    let count: Int

    func call(_ path: String, query: [String: String]) async throws(ChiefMemoryError) -> Data {
        switch path {
        case "/api/status": return Data(#"{"messages": 64, "nodes_built": 127, "stale": [], "editable": true}"#.utf8)
        case "/api/memory/changes": return Data(#"{"changes": [], "stale": []}"#.utf8)
        case "/api/node":
            return Data((#"{"name": "4+1", "level": 0, "start": 4, "n": 1, "built": true, "text": "user: hello", "#
                + #""message": {"id": 4, "kind": "user", "text": "hello there", "bytes": 11}}"#).utf8)
        case "/api/view":
            let lines = (0..<count).map {
                #"{"name": "rc\#(count)-\#($0)", "level": 1, "start": \#($0), "n": 1, "built": true, "text": "line \#($0)"}"#
            }
            return Data((#"{"lines": ["# + lines.joined(separator: ",") + "]}").utf8)
        default: throw .refused(status: 404, message: "no API \(path)")
        }
    }
}

/// The row ids a list reported as it drew (`EnvironmentValues.rowDrawn`).
@MainActor private final class Draws {
    var ids: [String] = []

    /// The ids drawn since the last take, then forgets them.
    func take() -> [String] {
        defer { ids = [] }
        return ids
    }
}

/// Leo 2026-11-18: "we draw the visible area, right?" The Memory Inspector's view list draws the
/// lines in view at 100 lines as at 10,000, and a change draws only the lines it changed: a line
/// opened draws the line it leaves and the line it opens, a key typed in the search field and a
/// reload of the same view draw none. Each run prints its counts ("chief-memory-row-counts").
@MainActor @Suite(.serialized) struct ChiefMemoryRowCountTests {
    /// Lets SwiftUI apply what changed, then lays the inspector out.
    static func settle(_ view: NSView) {
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            view.layoutSubtreeIfNeeded()
        }
    }

    /// The line names `change` drew, in draw order.
    static func drawn(_ view: NSView, _ probe: Draws, _ change: () async -> Void) async -> [String] {
        _ = probe.take()
        await change()
        settle(view)
        return probe.take()
    }

    @Test(arguments: [100, 10_000])
    func theListDrawsTheLinesInViewAndAChangeDrawsOnlyItsLines(count: Int) async throws {
        _ = NSApplication.shared
        let model = ChiefMemoryInspectorModel(source: ManyLines(count: count), confirmDelete: { _, _ in true })
        await model.reload()
        let height: CGFloat = 600
        let probe = Draws()
        let host = NSHostingView(rootView: ChiefMemoryInspectorView(model: model).environment(\.rowDrawn) { probe.ids.append($0) })
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 900, height: height)
        window.orderFrontRegardless()
        // The newest line is on top.
        let (top, second) = ("rc\(count)-\(count - 1)", "rc\(count)-\(count - 2)")

        let mounted = Set(await Self.drawn(host, probe) { Self.settle(host) }).count
        let bound = 3 * Int(height / 30)
        _ = await Self.drawn(host, probe) { await model.open(top) }
        let opened = await Self.drawn(host, probe) { await model.open(second) }
        let typed = await Self.drawn(host, probe) { model.query = "a" }
        let reloaded = await Self.drawn(host, probe) { await model.reload() }
        print("chief-memory-row-counts n=\(count) mounted=\(mounted) bound=\(bound) open=\(opened.count) "
            + "typed=\(typed.count) reload=\(reloaded.count)")

        #expect(mounted > 0 && mounted <= bound, "lines drawn at mount: \(mounted), viewport and overscan hold \(bound)")
        #expect(Set(opened) == [top, second], "opening a line drew \(opened.count) lines: \(opened.prefix(8))")
        #expect(typed.isEmpty, "a key in the search field drew \(typed.count) lines")
        #expect(reloaded.isEmpty, "a reload of the same view drew \(reloaded.count) lines")
    }
}
