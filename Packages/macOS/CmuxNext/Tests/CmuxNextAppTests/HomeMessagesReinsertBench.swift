import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextHome
import CmuxHomeCore
import CmuxNextTestSupport
@testable import MessagesLabSidebar
import QuartzCore
import Testing

/// FRAME OWNER REFACTOR S7b, the measure before the docked Home's Messages view leaves the window while it is parked
/// (pixel-perfect's condition 1, 2026-11-04): what showing it again costs. In the S7 films the parked docked Home laid
/// its native Messages view (`TopHomePageView`: the conversation list and the transcript) out on every step of a window
/// resize, 141 calls per view in an ON film of 72 steps (`debug.layers` `top_instances`), mostly SwiftUI hosting views,
/// which lay out on every step even when their frame does not change (ParkedPageWindowResizeLayoutTests).
///
/// Three ways to park the page while the window resizes, each shown again after one resize step at the new size:
/// - `today`: hidden, it follows its holder (the pane today);
/// - `frozen`: hidden at the frame it had (the frame part of S7b), sized once when it shows;
/// - `detached`: out of the window (S7b's Messages part), put back and sized when it shows.
/// Per show: the re-insert or unhide, the layout, the display and the commit, and the layout calls the next turns still
/// make (work the show left for a later frame). Per parked resize step: its time and its layout calls.
///
/// A bench, not a test: it runs only with `CMUX_HOME_REINSERT_BENCH=1` (on the fleet, `--env`), on a display worker.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)), .closesItsWindows,
       .enabled(if: ProcessInfo.processInfo.environment["CMUX_HOME_REINSERT_BENCH"] == "1"))
struct HomeMessagesReinsertBench {
    enum Park: String, CaseIterable {
        case today, frozen, detached
    }

    struct Show {
        var insert = 0.0, layout = 0.0, display = 0.0, commit = 0.0
        var total: Double { insert + layout + display + commit }
        var dirtyAfter = 0
        var laterLayouts = 0
    }

    struct Step {
        var milliseconds = 0.0
        var layouts = 0
    }

    static let rows = (0..<28).map { "conv_reinsert_\($0)" }
    static let pinned = ["conv_reinsert_pin_a", "conv_reinsert_pin_b"]

    private static func ms(_ start: CFTimeInterval) -> Double { (CACurrentMediaTime() - start) * 1000 }

    private static func quantile(_ values: [Double], _ q: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .nan }
        return sorted[min(sorted.count - 1, Int((q * Double(sorted.count - 1)).rounded()))]
    }

    private static func line(_ name: String, _ values: [Double]) -> String {
        String(format: "%@ p50 %.2f p95 %.2f max %.2f (n %ld)", name, quantile(values, 0.5), quantile(values, 0.95),
               values.max() ?? .nan, values.count)
    }

    /// Views under `root` (root included) that still need layout, display or a constraint update.
    private static func dirty(_ root: NSView) -> Int {
        var count = 0
        var stack = [root]
        while let view = stack.popLast() {
            if view.needsLayout || view.needsDisplay || view.needsUpdateConstraints { count += 1 }
            stack.append(contentsOf: view.subviews)
        }
        return count
    }

    /// One step of a window resize from its lower-left corner (the films' drag): smaller on even steps, back on odd ones.
    private static func resize(_ window: NSWindow, step: Int) {
        var frame = window.frame
        let sign: CGFloat = step.isMultiple(of: 2) ? 1 : -1
        frame.origin.x += 20 * sign
        frame.size.width -= 20 * sign
        frame.origin.y += 12 * sign
        frame.size.height -= 12 * sign
        window.setFrame(frame, display: false)
    }

    @Test func showingTheParkedMessagesViewAgainAfterAWindowResize() async throws {
        _ = NSApplication.shared
        LayoutPassGuard.shared.install()
        let services = AppServices(environment: AppEnvironment.current([:]))
        let page = TopHomePageView(services: services, windowKey: { "reinsert-bench" })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            if let host = page.host, let popup = Mirror(reflecting: host).descendant("settings", "popup") as? NativePopupHost {
                popup.closePanel()
            }
            window.close()
        }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        window.contentView = root
        // The pane's content area; what shows while the Home is parked (a terminal) fills it too.
        let holder = NSView(frame: root.bounds)
        holder.autoresizingMask = [.width, .height]
        root.addSubview(holder)
        let other = NSView(frame: holder.bounds)
        other.wantsLayer = true
        other.autoresizingMask = [.width, .height]
        holder.addSubview(other)
        page.frame = holder.bounds
        page.autoresizingMask = [.width, .height]
        holder.addSubview(page)
        if let visible = NSScreen.main?.visibleFrame { window.setFrameOrigin(NSPoint(x: visible.minX + 60, y: visible.minY + 60)) }
        window.orderFrontRegardless()
        let now = Date()
        let entries = (Self.pinned + Self.rows).enumerated().map { index, id in
            CmuxSidebarEntry(id: id, title: id, people: [CmuxSidebarEntry.Person(id: "p\(index)", name: id, initials: "P")],
                             preview: "hi", previewSender: nil, lastAt: now.addingTimeInterval(-Double(index) * 60),
                             unreadCount: 0, pinned: Self.pinned.contains(id))
        }
        // The page's own (empty, offline) inbox model lands on its first turns; the list then shows these items.
        for _ in 0..<50 { await Task.yield() }
        page.list.list.show(entries, pinned: Self.pinned)
        page.layoutSubtreeIfNeeded()
        page.show(ConversationID(Self.rows[0]))
        for _ in 0..<200 where page.host?.focusTarget == nil { await Task.yield() }
        root.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        let views = { () -> Int in
            var count = 0
            var stack: [NSView] = [page]
            while let view = stack.popLast() { count += 1; stack.append(contentsOf: view.subviews) }
            return count
        }()

        var shows: [Park: [Show]] = [:], steps: [Park: [Step]] = [:]
        var resizeCount = 0
        let warmUp = 3, rounds = 20
        for round in 0..<(warmUp + rounds) {
            for park in Park.allCases {
                // Parked: what shows in the pane is the other view.
                other.isHidden = false
                switch park {
                case .today:
                    page.isHidden = true
                case .frozen:
                    page.isHidden = true
                    page.autoresizingMask = []
                case .detached:
                    page.removeFromSuperview()
                }
                root.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                CATransaction.flush()

                // One step of the window's resize while it is parked.
                var step = Step()
                let calls = LayoutPassGuard.shared.viewLayoutCalls
                let stepStart = CACurrentMediaTime()
                Self.resize(window, step: resizeCount)
                resizeCount += 1
                root.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                CATransaction.flush()
                step.milliseconds = Self.ms(stepStart)
                step.layouts = LayoutPassGuard.shared.viewLayoutCalls - calls

                // Shown again at the holder's size now.
                var show = Show()
                var start = CACurrentMediaTime()
                switch park {
                case .today:
                    page.isHidden = false
                case .frozen:
                    page.frame = holder.bounds
                    page.autoresizingMask = [.width, .height]
                    page.isHidden = false
                case .detached:
                    page.frame = holder.bounds
                    holder.addSubview(page)
                }
                other.isHidden = true
                show.insert = Self.ms(start)
                start = CACurrentMediaTime()
                root.layoutSubtreeIfNeeded()
                show.layout = Self.ms(start)
                start = CACurrentMediaTime()
                window.displayIfNeeded()
                show.display = Self.ms(start)
                start = CACurrentMediaTime()
                CATransaction.flush()
                show.commit = Self.ms(start)
                show.dirtyAfter = Self.dirty(page)
                // What the show left for later turns (its views' own async updates), laid out the way a next frame would.
                let before = LayoutPassGuard.shared.viewLayoutCalls
                for _ in 0..<20 { await Task.yield() }
                root.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                CATransaction.flush()
                show.laterLayouts = LayoutPassGuard.shared.viewLayoutCalls - before

                #expect(page.window === window && page.frame.size == holder.bounds.size,
                        "\(park.rawValue): the page is not shown at its holder's size (\(page.frame.size) in \(holder.bounds.size))")
                guard round >= warmUp else { continue }
                shows[park, default: []].append(show)
                steps[park, default: []].append(step)
            }
        }

        var report = ["HomeMessagesReinsertBench: Messages view of \(views) views, message box \(page.host?.focusTarget != nil ? "in" : "not in"),"
                      + " window \(Int(window.frame.width))x\(Int(window.frame.height)), \(rounds) shows per way (ms)"]
        for park in Park.allCases {
            let s = shows[park] ?? [], p = steps[park] ?? []
            report.append("\(park.rawValue):")
            report.append("  show " + Self.line("total", s.map(\.total)))
            report.append("  show " + Self.line("insert", s.map(\.insert)) + "; " + Self.line("layout", s.map(\.layout)))
            report.append("  show " + Self.line("display", s.map(\.display)) + "; " + Self.line("commit", s.map(\.commit)))
            report.append("  show " + Self.line("dirty views after", s.map { Double($0.dirtyAfter) })
                          + "; " + Self.line("layouts in later turns", s.map { Double($0.laterLayouts) }))
            report.append("  parked step " + Self.line("time", p.map(\.milliseconds)) + "; " + Self.line("layouts", p.map { Double($0.layouts) }))
        }
        let today = (shows[.today] ?? []).map(\.total), detached = (shows[.detached] ?? []).map(\.total)
        report.append(String(format: "detached minus today: show total p50 %+.2f, p95 %+.2f",
                             Self.quantile(detached, 0.5) - Self.quantile(today, 0.5), Self.quantile(detached, 0.95) - Self.quantile(today, 0.95)))
        print(report.joined(separator: "\n"))
    }
}
