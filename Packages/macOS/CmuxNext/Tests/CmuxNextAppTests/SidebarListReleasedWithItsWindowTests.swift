import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// A sidebar list whose window closed is freed with it: nothing in the app keeps its views, rows, status indicators or
/// model alive. `PinnedRowsShareHomeColumnTests` (901 cases since #44449 gave every case all five density presets) ran
/// slower with every case, 0.3 s a case at the start and over 2 s near the end, until the suite's 900 s watchdog
/// stopped it: every earlier case's list stayed alive and laid out again on each later case's settings change.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarListReleasedWithItsWindowTests {
    /// Weak references to what one case made.
    struct Made {
        weak var list: SidebarListView?
        weak var window: NSWindow?
        weak var model: SidebarModel?
        var rows: [Weak] = []
        var regions: [Weak] = []
        var indicators: [Weak] = []

        /// The objects still alive, by kind.
        var alive: [String] {
            (list == nil ? [] : ["list"]) + (window == nil ? [] : ["window"]) + (model == nil ? [] : ["model"])
                + Self.names("row", rows) + Self.names("region", regions) + Self.names("indicator", indicators)
        }

        static func names(_ kind: String, _ refs: [Weak]) -> [String] {
            refs.compactMap { $0.object.map { "\(kind) \(type(of: $0))" } }
        }
    }

    struct Weak { weak var object: AnyObject? }

    /// Builds the pinned rows' list as `PinnedRowsShareHomeColumnTests` does at `c`, lays it out, closes its window,
    /// and returns weak references to what it made.
    static func makeAndClose(_ c: PinnedRowsShareHomeColumnTests.Case, preset: DensityPreset, pinnedGroup: Bool) throws -> Made {
        var made = Made()
        try PinnedRowsShareHomeColumnTests.at(c, preset: preset) {
            autoreleasepool {
                let (list, window) = PinnedRowsShareHomeColumnTests.list(scale: c.scale, pinnedGroup: pinnedGroup)
                made.list = list
                made.window = window
                made.model = list.model
                let regions = list.blockRegions
                made.regions = regions.map { Weak(object: $0) }
                let items = regions.flatMap { Array($0.itemViews.values) }
                made.rows = items.map { Weak(object: $0) } + list.rowViews.values.map { Weak(object: $0) }
                made.indicators = items.map { Weak(object: $0.activity) }
                window.close()
            }
        }
        return made
    }

    @Test(arguments: [false, true])
    func aClosedListLeavesNothingAlive(pinnedGroup: Bool) throws {
        let c = PinnedRowsShareHomeColumnTests.Case(density: .compact, minimal: .off, textSize: .standard, scale: 2)
        let made = try Self.makeAndClose(c, preset: .compact, pinnedGroup: pinnedGroup)
        if let list = made.list {
            // DIAG (scratch only): who holds the closed list. `leaks --referenceTree` names the paths to it.
            let address = String(format: "%p", unsafeBitCast(list, to: Int.self))
            print("LEAKDIAG list \(address) retain=\(CFGetRetainCount(list)) superview=\(String(describing: list.superview)) window=\(String(describing: list.window))")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/leaks")
            p.arguments = ["\(ProcessInfo.processInfo.processIdentifier)", "--referenceTree", "--groupByType", "--debug=no-symbolication"]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            try? p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            for line in text.split(separator: "\n") where line.contains("SidebarListView") || line.contains(address) {
                print("LEAKDIAG ref \(line.prefix(300))")
            }
        }
        #expect(made.alive.isEmpty, "alive after the window closed: \(made.alive)")
    }

    /// Ten cases one after another leave no list behind, so a later case never lays out an earlier case's rows.
    @Test func casesDoNotAccumulate() throws {
        var lists: [Weak] = []
        for preset in DensityPreset.allCases {
            for scale in [CGFloat(1), 2] {
                let c = PinnedRowsShareHomeColumnTests.Case(density: .compact, minimal: .off, textSize: .standard, scale: scale)
                let made = try Self.makeAndClose(c, preset: preset, pinnedGroup: false)
                lists.append(Weak(object: made.list))
            }
        }
        let alive = lists.compactMap(\.object).count
        #expect(alive == 0, "\(alive) of \(lists.count) closed lists still alive")
    }
}
