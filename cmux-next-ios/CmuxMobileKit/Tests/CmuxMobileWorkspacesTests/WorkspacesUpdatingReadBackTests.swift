#if os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileWorkspaces

/// Read-back of the Workspaces page's "Updating…" subtitle on the real screen (Leo, 2026-11-14:
/// "i also want all our connectivity stuff to shut the f*** up and load faster"): `WorkspacesList`
/// in a window over rows the phone has, while the team's refresh never ends. At 3 s the subtitle
/// says nothing about it; past the quiet bound (10 s, on the real clock the screen uses) it says
/// "Updating…" (screenshots: HomeKeptUpdatingUITests, in the real app).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2))) struct WorkspacesUpdatingReadBackTests {
    @Test func readBackRefreshAt3sAndPast10s() async throws {
        let store = AppStore.mock()
        // A refresh that does not end while the rows show.
        store.teamDataState = .loading
        let creator = WorkspaceCreator(store: store, backend: MockWorkspaceCreationBackend(latency: .zero))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            WorkspacesList(store: store, creator: creator, open: { _ in })
        })
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let shown = ContinuousClock.now

        var log: [String] = []
        await pump(until: shown.advanced(by: .seconds(3)))
        let early = updating(in: window)
        log.append(line("1-refresh-3s-silent", since: shown, updating: early))
        #expect(!early, "no Updating subtitle at 3 s of a refresh: \(subtitles(in: window))")

        await pump(until: shown.advanced(by: QuietStatusGate.threshold + .seconds(1)))
        let late = updating(in: window)
        log.append(line("2-refresh-past-10s-updating", since: shown, updating: late))
        #expect(late, "past the quiet bound the subtitle says Updating: \(subtitles(in: window))")

        Attachment.record(log.joined(separator: "\n") + "\n", named: "workspaces-readback.txt")
        print(log.joined(separator: "\n"))
    }

    /// Suspends the test until `deadline`: the main actor is free meanwhile, so SwiftUI's updates
    /// and the screen's own task (its quiet wait on the real clock) run as in the app.
    private func pump(until deadline: ContinuousClock.Instant) async {
        try? await ContinuousClock().sleep(until: deadline, tolerance: .milliseconds(50))
        for _ in 0 ..< 10 { await Task.yield() }
    }

    /// The navigation subtitles and every label in the window.
    private func subtitles(in window: UIWindow) -> [String] {
        func navigations(_ controller: UIViewController?) -> [UINavigationController] {
            guard let controller else { return [] }
            return ((controller as? UINavigationController).map { [$0] } ?? []) + controller.children.flatMap { navigations($0) }
        }
        func labels(_ view: UIView) -> [String] {
            ((view as? UILabel)?.text.map { [$0] } ?? []) + view.subviews.flatMap(labels)
        }
        let items = navigations(window.rootViewController).flatMap(\.viewControllers).compactMap { $0.navigationItem.subtitle }
        return items + labels(window)
    }

    private func updating(in window: UIWindow) -> Bool {
        subtitles(in: window).contains("Updating…")
    }

    private func line(_ name: String, since start: ContinuousClock.Instant, updating: Bool) -> String {
        let parts = (ContinuousClock.now - start).components
        let ms = parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000
        return "\(name.padding(toLength: 28, withPad: " ", startingAt: 0)) t=\(ms)ms  updating=\(updating)"
    }
}
#endif
