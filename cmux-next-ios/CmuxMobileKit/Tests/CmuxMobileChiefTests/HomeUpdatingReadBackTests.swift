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

        var log: [String] = []
        ScreenReadBack.pump(until: shown.advanced(by: .seconds(3)))
        let early = ScreenReadBack.strings(in: window)
        log.append(ScreenReadBack.line("1-kept-3s-silent", since: shown, updating: early.contains("home.note.updating")))
        ScreenReadBack.record(window, named: "home-1-kept-3s.png")
        #expect(feed.isShowingKeptRows, "the Mac's list never came: the rows are the kept ones")
        #expect(!early.contains("home.note.updating"), "no Updating capsule over kept rows at 3 s: \(early.sorted())")

        // Past the quiet bound (QuietStatusGate.threshold, 10 s) by 1 s.
        ScreenReadBack.pump(until: shown.advanced(by: .seconds(11)))
        let late = ScreenReadBack.strings(in: window)
        log.append(ScreenReadBack.line("2-kept-past-10s-updating", since: shown, updating: late.contains("home.note.updating")))
        ScreenReadBack.record(window, named: "home-2-kept-past-10s.png")
        #expect(late.contains("home.note.updating"), "past the quiet bound the Updating capsule shows: \(late.sorted())")

        Attachment.record(log.joined(separator: "\n") + "\n", named: "home-readback.txt")
        print(log.joined(separator: "\n"))
    }
}

/// Drives a hosted screen on the real run loop, reads what it shows, and saves it.
@MainActor
enum ScreenReadBack {
    /// Runs the main run loop (SwiftUI's updates, main-actor tasks, the screen's clock) until `deadline`.
    static func pump(until deadline: ContinuousClock.Instant) {
        while ContinuousClock.now < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// Every accessibility identifier and label in the window (views and SwiftUI's elements).
    static func strings(in window: UIWindow) -> Set<String> {
        var found = Set<String>()
        var seen = Set<ObjectIdentifier>()
        func visit(_ element: NSObject, depth: Int) {
            guard depth < 64, seen.insert(ObjectIdentifier(element)).inserted else { return }
            if let id = (element as? UIAccessibilityIdentification)?.accessibilityIdentifier, !id.isEmpty { found.insert(id) }
            if let label = element.accessibilityLabel, !label.isEmpty { found.insert(label) }
            if let text = (element as? UILabel)?.text, !text.isEmpty { found.insert(text) }
            if let view = element as? UIView { for sub in view.subviews { visit(sub, depth: depth + 1) } }
            if let elements = element.accessibilityElements as? [NSObject] {
                for child in elements { visit(child, depth: depth + 1) }
            } else {
                let count = element.accessibilityElementCount()
                if count != NSNotFound, count > 0 {
                    for index in 0 ..< count {
                        if let child = element.accessibilityElement(at: index) as? NSObject { visit(child, depth: depth + 1) }
                    }
                }
            }
        }
        visit(window, depth: 0)
        return found
    }

    static func line(_ name: String, since start: ContinuousClock.Instant, updating: Bool) -> String {
        let ms = (ContinuousClock.now - start).components
        let total = ms.seconds * 1000 + ms.attoseconds / 1_000_000_000_000_000
        return "\(name.padding(toLength: 26, withPad: " ", startingAt: 0)) t=\(total)ms  updating=\(updating)"
    }

    /// The window as drawn, saved as a test attachment.
    static func record(_ window: UIWindow, named name: String) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let shot = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        if let png = shot.pngData() { Attachment.record(png, named: name) }
    }
}
#endif
