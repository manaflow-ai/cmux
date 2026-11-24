#if os(iOS)
import CmuxMobileModel
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileAgentChat

/// A working row's elapsed time ("Working · 12s") redraws once a second while
/// it is seen, and not at all while nobody can see it: its row scrolled out of
/// the transcript (the cell parked in the list's reuse pool, its hosted view
/// alive) or the app in the background (`MinuteClock.setActive(false)`, which
/// RootView calls on the background phase). The energy bench saw it redraw
/// 63 to 66 times a minute in both (cmux#42818). Each case counts the redraws
/// of one label in real time (the schedule is the system's), so the waits are
/// whole seconds.
@MainActor
@Suite(.serialized) struct WorkingLabelUnseenTickTests {
    /// A label 30 s into its turn (past the quiet first 5 s): it redraws every second.
    static func start() -> Date { Date().addingTimeInterval(-30.25) }

    static func redraws(_ since: Date) -> Int { WorkingLabel.redrawCounts[since] ?? 0 }

    static func wait(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    static func window(_ root: UIViewController) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = root
        window.makeKeyAndVisible()
        root.view.layoutIfNeeded()
        return window
    }

    @Test func theAppInTheBackgroundStopsTheTime() async {
        let since = Self.start()
        WorkingLabel.redrawCounts[since] = 0
        defer { WorkingLabel.redrawCounts[since] = nil; MinuteClock.shared.setActive(true) }
        let window = Self.window(UIHostingController(rootView: WorkingLabel("Working", since: since)))
        defer { window.isHidden = true }
        await Self.wait(3.2)
        let seen = Self.redraws(since)
        #expect(seen >= 2, "on screen it redraws every second, got \(seen) in 3.2 s")

        MinuteClock.shared.setActive(false)
        await Self.wait(0.3)
        let backgrounded = Self.redraws(since)
        await Self.wait(3.2)
        let unseen = Self.redraws(since) - backgrounded
        print("WorkingLabelUnseenTickTests: background: \(unseen) redraws in 3.2 s (\(seen) seen before)")
        #expect(unseen == 0, "in the background it redrew \(unseen) times in 3.2 s")

        // Back in front: the time is current at once, then ticks again.
        MinuteClock.shared.setActive(true)
        await Self.wait(2.2)
        #expect(Self.redraws(since) - backgrounded >= 2)
    }

    @Test func aRowScrolledOutOfTheListStopsTheTime() async {
        let since = Self.start()
        WorkingLabel.redrawCounts[since] = 0
        defer { WorkingLabel.redrawCounts[since] = nil }
        let list = HostedRowsController(since: since, rows: 200)
        let window = Self.window(list)
        defer { window.isHidden = true }
        await Self.wait(3.2)
        let seen = Self.redraws(since)
        #expect(seen >= 2, "on screen it redraws every second, got \(seen) in 3.2 s")

        // As a reader does: scroll to the other end of a long transcript.
        let view = list.collectionView
        view.setContentOffset(CGPoint(x: 0, y: view.contentSize.height - view.bounds.height), animated: false)
        view.layoutIfNeeded()
        await Self.wait(0.3)
        let away = Self.redraws(since)
        await Self.wait(3.2)
        let unseen = Self.redraws(since) - away
        print("WorkingLabelUnseenTickTests: scrolled away: \(unseen) redraws in 3.2 s (\(seen) seen before)")
        #expect(!view.indexPathsForVisibleItems.contains(IndexPath(item: 0, section: 0)), "the working row is off screen")
        #expect(unseen == 0, "off screen it redrew \(unseen) times in 3.2 s")

        // Scrolled back: it ticks again.
        view.setContentOffset(.zero, animated: false)
        view.layoutIfNeeded()
        await Self.wait(2.2)
        #expect(Self.redraws(since) - away - unseen >= 2)
    }

    /// The cell of a working row scrolled away is parked (its label unseen), then reused for a
    /// new turn still in its quiet first 5 s, whose time draws nothing yet. Back on screen it
    /// ticks once those seconds pass: the label notes that it is seen again even while its time
    /// is empty, and a new turn does not keep the old turn's unseen state.
    @Test func aReusedRowWithANewTurnTicksOnceItsQuietSecondsPass() async {
        let list = HostedRowsController(since: Self.start(), rows: 200)
        let window = Self.window(list)
        defer { window.isHidden = true }
        await Self.wait(1.2)
        let view = list.collectionView
        let first = IndexPath(item: 0, section: 0)
        let parked = view.cellForItem(at: first)
        view.setContentOffset(CGPoint(x: 0, y: view.contentSize.height - view.bounds.height), animated: false)
        view.layoutIfNeeded()
        await Self.wait(0.3)

        // A new turn, 1 s old, then back to the top (the scroll dequeues the parked cell from
        // the working row's own pool): its time is empty until 5 s.
        let since = Date().addingTimeInterval(-1)
        WorkingLabel.redrawCounts[since] = 0
        defer { WorkingLabel.redrawCounts[since] = nil }
        list.since = since
        // As the transcript does when a row's model changes off screen.
        view.reloadItems(at: [first])
        view.setContentOffset(.zero, animated: false)
        view.layoutIfNeeded()
        #expect(parked != nil && view.cellForItem(at: first) === parked, "the working row came back in its parked cell")
        #expect(list.configured == since, "the row came back configured with the new turn")
        await Self.wait(7.2)
        let ticks = Self.redraws(since)
        print("WorkingLabelUnseenTickTests: reused row, new turn: \(ticks) redraws in 7.2 s")
        #expect(view.indexPathsForVisibleItems.contains(first), "the working row is on screen")
        #expect(ticks >= 3, "a seen row past its quiet seconds redraws every second, got \(ticks) in 7.2 s")
    }
}

/// A list like the transcript's: a collection view of hosted SwiftUI rows
/// (`UIHostingConfiguration`), the first a working row in a reuse pool of its own.
@MainActor
final class HostedRowsController: UIViewController, UICollectionViewDataSource {
    /// The working row's turn start; a new turn reconfigures the row in the same cell.
    var since: Date
    /// The turn start the working row was last configured with.
    private(set) var configured: Date?
    let rows: Int
    let collectionView: UICollectionView

    init(since: Date, rows: Int) {
        self.since = since
        self.rows = rows
        let layout = UICollectionViewFlowLayout()
        layout.itemSize = CGSize(width: 390, height: 44)
        layout.minimumLineSpacing = 0
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.frame = view.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "row")
        // Its own reuse pool, as the transcript pools hosted rows by kind: scrolled away, the
        // working row's cell is parked with its label, not reused for another row.
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "working")
        collectionView.dataSource = self
        view.addSubview(collectionView)
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { rows }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: indexPath.item == 0 ? "working" : "row", for: indexPath)
        let since = since
        if indexPath.item == 0 {
            configured = since
            cell.contentConfiguration = UIHostingConfiguration { WorkingLabel("Working", since: since) }
        } else {
            cell.contentConfiguration = UIHostingConfiguration { Text("Row \(indexPath.item)") }
        }
        return cell
    }
}
#endif
