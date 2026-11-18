#if os(iOS)
import CmuxConversationCore
import CmuxMobileModel
import CmuxMobileTransport
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileChief

/// Read-back of Home's kept rows on the real screen (Leo, 2026-11-14: "i also want all our
/// connectivity stuff to shut the f*** up and load faster"): `ConversationsHome` in a window,
/// over a feed that shows the rows kept from an earlier read while the Mac's list never comes.
/// At 3 s the list shows with no "Updating…" capsule; past the quiet bound (10 s, on the real
/// clock the screen uses) the capsule shows. Each state is saved as a screenshot attachment.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2))) struct HomeUpdatingReadBackTests {
    struct Home: View {
        let sources: ChiefSources
        let feed: MacHomeFeed
        let store = AppStore(teams: [], activeTeamID: "", workspaces: [], feed: [])

        var body: some View {
            NavigationStack {
                ConversationsHome(store: store, sources: sources, feed: feed, open: { _ in }) {
                    ToolbarItem(placement: .topBarLeading) { EmptyView() }
                }
            }
        }
    }

    @Test func readBackKeptRowsAt3sAndPast10s() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "home-readback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = MacHomeKeptTests.Account()
        // An earlier run read the Mac's list and kept it.
        let first = MacHomeRowsCache(directory: directory, writeDelay: .milliseconds(0))
        let owner = FakeHomeOwner()
        let read = MacHomeKeptTests.feed(first, account: account)
        await read.connect(link: MockMacLink { _, request in owner.respond(request) }, macID: "mac-1")
        #expect(await eventually { read.rows?.count == 4 })
        first.flush()

        // A launch: the kept rows from disk, and the Mac's list never answers.
        let feed = MacHomeKeptTests.feed(MacHomeRowsCache(directory: directory, writeDelay: .milliseconds(0)), account: account)
        feed.showKeptRows(of: "mac-1")
        #expect(await eventually { feed.rows?.count == 4 && feed.isShowingKeptRows })

        let mac = ChiefSession(backend: ChiefOfflineBackend(), outbox: ChiefOutbox(file: nil), clock: ImmediateClock())
        let cloud = ChiefSession(backend: ChiefOfflineBackend(), outbox: ChiefOutbox(file: nil), clock: ImmediateClock())
        let sources = ChiefSources(mac: mac, cloud: cloud, selection: UserDefaults(suiteName: "home-readback-\(UUID())")!)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UIHostingController(rootView: Home(sources: sources, feed: feed))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let shown = ContinuousClock.now

        // The capsule draws at the bottom centre, under the four rows, where the page is
        // otherwise its plain background: count the pixels there that are not background.
        var log: [String] = []
        await ScreenReadBack.pump(until: shown.advanced(by: .seconds(3)))
        let early = ScreenReadBack.record(window, named: "home-1-kept-3s.png")
        let earlyInk = ScreenReadBack.capsuleInk(early, in: window)
        log.append(ScreenReadBack.line("1-kept-3s-silent", since: shown, ink: earlyInk))
        #expect(feed.isShowingKeptRows, "the Mac's list never came: the rows are the kept ones")
        #expect(earlyInk >= 0 && earlyInk < 40, "no Updating capsule over kept rows at 3 s: \(earlyInk) capsule-area pixels drawn")

        // Past the quiet bound (QuietStatusGate.threshold, 10 s) by 1 s.
        await ScreenReadBack.pump(until: shown.advanced(by: .seconds(11)))
        let late = ScreenReadBack.record(window, named: "home-2-kept-past-10s.png")
        let lateInk = ScreenReadBack.capsuleInk(late, in: window)
        log.append(ScreenReadBack.line("2-kept-past-10s-updating", since: shown, ink: lateInk))
        #expect(feed.isShowingKeptRows, "still the kept rows")
        #expect(lateInk > 400, "past the quiet bound the Updating capsule shows: \(lateInk) capsule-area pixels drawn")

        Attachment.record(log.joined(separator: "\n") + "\n", named: "home-readback.txt")
        print(log.joined(separator: "\n"))
    }
}

/// Drives a hosted screen on the real clock, and saves and reads what it draws.
@MainActor
enum ScreenReadBack {
    /// Suspends the test until `deadline`: the main actor is free meanwhile, so SwiftUI's
    /// updates and the screen's own tasks (its quiet gate on the real clock) run as in the app.
    static func pump(until deadline: ContinuousClock.Instant) async {
        try? await ContinuousClock().sleep(until: deadline, tolerance: .milliseconds(50))
        for _ in 0 ..< 10 { await Task.yield() }
    }

    static func line(_ name: String, since start: ContinuousClock.Instant, ink: Int) -> String {
        let parts = (ContinuousClock.now - start).components
        let ms = parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000
        return "\(name.padding(toLength: 26, withPad: " ", startingAt: 0)) t=\(ms)ms  capsule_pixels=\(ink)"
    }

    /// The window as drawn, saved as a test attachment.
    @discardableResult
    static func record(_ window: UIWindow, named name: String) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let shot = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        if let png = shot.pngData() { Attachment.record(png, named: name) }
        return shot
    }

    /// Pixels in the capsule's area (bottom centre, 200 x 70 pt above the safe area) that differ
    /// from the page background, read at the bottom-left corner beside it.
    static func capsuleInk(_ image: UIImage, in window: UIWindow) -> Int {
        guard let cg = image.cgImage else { return -1 }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn, width > 220 else { return -1 }
        let bottom = height - Int(window.safeAreaInsets.bottom)
        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * width + x) * 4
            return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
        }
        let background = rgb(8, bottom - 30)
        var ink = 0
        for y in max(0, bottom - 70) ..< bottom {
            for x in (width / 2 - 100) ..< (width / 2 + 100) {
                let (r, g, b) = rgb(x, y)
                if abs(r - background.0) + abs(g - background.1) + abs(b - background.2) > 24 { ink += 1 }
            }
        }
        return ink
    }
}
#endif
