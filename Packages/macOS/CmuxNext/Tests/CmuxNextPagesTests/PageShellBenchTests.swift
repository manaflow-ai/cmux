import AppKit
@testable import CmuxNextPages
import CmuxNextSettings
import Foundation
import QuartzCore
import Testing
import WebKit

/// The claim bench (GUI host only, cmux-lawrence-2; opt in with CMUX_PAGE_SHELL_BENCH=1): the icon
/// picker claimed from a parked spare in the same window and across windows, timed from the claim
/// to the page's next animation frame after the mount, plus the footprint of one parked host.
/// Prints one `PAGE_SHELL_BENCH {json}` line and writes it to $NX_ARTIFACTS when set. Two small
/// non-activating panels; the test never activates the app.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)), .enabled(if: ProcessInfo.processInfo.environment["CMUX_PAGE_SHELL_BENCH"] == "1"))
struct PageShellBenchTests {
    static let rounds = 20

    func panel(x: CGFloat) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: x, y: 40, width: 352, height: 420),
                            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 352, height: 420))
        panel.isReleasedWhenClosed = false
        panel.orderFrontRegardless()
        return panel
    }

    static func stats(_ values: [Double]) -> [String: Double] {
        let sorted = values.sorted()
        func at(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int(q * Double(sorted.count)))] }
        return ["n": Double(sorted.count), "p50": at(0.5), "p95": at(0.95), "max": sorted.last ?? 0]
    }

    /// `footprint` of `pid` in MB (the "phys_footprint" summary line), or nil.
    static func footprintMB(_ pid: pid_t) -> Double? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/footprint")
        process.arguments = ["\(pid)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard let line = text.split(separator: "\n").first(where: { $0.contains("Footprint:") }) else { return nil }
        let parts = line.split(separator: " ").map(String.init)
        guard let index = parts.firstIndex(of: "Footprint:"), index + 2 < parts.count, let value = Double(parts[index + 1]) else { return nil }
        switch parts[index + 2].uppercased() {
        case "KB": return value / 1024
        case "GB": return value * 1024
        default: return value
        }
    }

    @Test func claimToFirstFrame() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        PageID.registerBundledRoot(PageShellFixture.webviewsApp, for: PageDescriptor.shell.id)
        let parked = panel(x: 40)
        let other = panel(x: 420)
        defer { parked.close(); other.close() }
        var all: [String: Any] = [:]
        // Shared pool first (as shipped), then a pool per host (the cost before R81's shared pool).
        for (mode, separate) in [("sharedPool", false), ("poolPerHost", true)] {
            PageProcessPool.separatePoolsForBench = separate
            defer { PageProcessPool.separatePoolsForBench = false }
            all[mode] = try await run(parked: parked, other: other)
        }
        let json = try JSONSerialization.data(withJSONObject: all, options: [.sortedKeys])
        let line = "PAGE_SHELL_BENCH " + String(decoding: json, as: UTF8.self)
        print(line)
        if let dir = ProcessInfo.processInfo.environment["NX_ARTIFACTS"] {
            try? Data(line.utf8).write(to: URL(fileURLWithPath: dir).appending(path: "page-shell-bench.json"))
        }
    }

    func run(parked: NSPanel, other: NSPanel) async throws -> [String: Any] {
        var policy = PageHostPool.Policy()
        policy.idleInput = .milliseconds(5)
        let pool = PageHostPool(policy: policy, activity: { 0 }, isTrackingMenu: { false })
        func spare() async {
            if pool.isSpareReady { return }
            _ = await PageTestWait.value("bench spare ready") { (done: @escaping (Bool) -> Void) in
                pool.onSpareReady = { _ in done(true) }
            }
        }
        let testProcessBefore = Self.footprintMB(getpid())
        pool.follow(parked)
        pool.noteLikely()
        await spare()
        print("PAGE_SHELL_BENCH_PROGRESS spare ready, loaded \(pool.spareHost?.isLoaded == true)")
        let spareHost = try #require(pool.spareHost)
        let webPID = (spareHost.webKitView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value
        let webContentMB = webPID.flatMap { Self.footprintMB($0) }
        let testProcessAfter = Self.footprintMB(getpid())

        var results: [String: Any] = [:]
        for (label, window) in [("sameWindow", parked), ("crossWindow", other)] {
            var claimMs: [Double] = []
            var mountedMs: [Double] = []
            var firstFrameMs: [Double] = []
            var cells: [Double] = []
            for round in 0..<Self.rounds {
                await spare()
                let session: JSONValue = ["id": .string("bench-\(round)"), "tab": "emoji"]
                pool.spareHost?.keepRenderingWhenCovered()
                var mountedAt: Double?
                var mountDone: ((Bool) -> Void)?
                let start = CACurrentMediaTime()
                let host = try #require(pool.claim(PageShellFixture.iconPicker, routes: [], context: session, window: window) { reply in
                    mountedAt = CACurrentMediaTime()
                    if case .failure(let error) = reply { print("PAGE_TEST_STAGE claim failed: \(error.code) \(error.message)") }
                    mountDone?(true)
                })
                if let content = window.contentView {
                    host.frame = content.bounds
                    content.addSubview(host)
                }
                claimMs.append((CACurrentMediaTime() - start) * 1000)
                PageTestWait.onTimeout = { await PageHostPoolTests.shellState(host) }
                if mountedAt == nil {
                    _ = await PageTestWait.value("bench claim mounted") { (done: @escaping (Bool) -> Void) in mountDone = done }
                }
                mountedMs.append(((mountedAt ?? start) - start) * 1000)
                let mounted = try await host.webKitView.callAsyncJavaScript(
                    """
                    const frame = await Promise.race([new Promise((r) => requestAnimationFrame(() => r(true))),
                                                      new Promise((r) => setTimeout(() => r(false), 500))]);
                    const cells = document.querySelectorAll('.icon-cell').length;
                    return frame ? cells : -cells - 1;
                    """,
                    contentWorld: .page) as? Int ?? 0
                // A console that never renders gives no animation frame: then only the mount is timed.
                if mounted >= 0 { firstFrameMs.append((CACurrentMediaTime() - start) * 1000) }
                cells.append(Double(mounted >= 0 ? mounted : -mounted - 1))
                #expect((mounted >= 0 ? mounted : -mounted - 1) > 0, "the picker mounted no cells")
                pool.release(host)
            }
            results[label] = [
                "claimMs": Self.stats(claimMs), "claimToMountedReplyMs": Self.stats(mountedMs),
                "claimToFirstFrameMs": firstFrameMs.isEmpty ? ["n": 0] : Self.stats(firstFrameMs),
                "cellsMounted": Self.stats(cells),
            ]
        }
        results["makeSpareMs"] = Self.stats(pool.spans.filter { $0.name == "pool.makeSpare" }.map(\.milliseconds))
        results["parkMs"] = Self.stats(pool.spans.filter { $0.name == "pool.makeSpare.park" }.map(\.milliseconds))
        results["webContentFootprintMB"] = webContentMB ?? -1
        results["testProcessFootprintMB"] = ["before": testProcessBefore ?? -1, "afterOneHost": testProcessAfter ?? -1]
        pool.dropSpare()
        return results
    }
}
