@testable import CmuxNextDesign
import CoreGraphics
import Foundation
import Testing

/// Placing a background by hand (backgrounds plan phase 6): the person's point sits at the
/// center of the visible span at their zoom, the art always still covers the window, the
/// automatic framing converts to a starting point, and placements persist by background id.
@MainActor @Suite struct BackdropUserPlacementTests {
    static let image = CGSize(width: 1600, height: 1000)
    static let view = CGSize(width: 1440, height: 900)
    static let metadata = BackdropArtMetadata(focalAnchor: .center, tone: .dark, dominantPalette: [],
                                              quietZone: .init(x: 0, y: 0, width: 0, height: 0))

    @Test func thePersonsPointSitsMidSpanAndTheArtStillCovers() {
        let centered = Self.metadata.placement(forViewSize: Self.view, imageSize: Self.image, visible: .whole,
                                               user: .init(centerX: 0.5, centerY: 0.5, zoom: 1))
        #expect(centered.contentsRect == CGRect(x: 0, y: 0, width: 1, height: 1) && !centered.fills)
        // Zoomed 2x on the right third: the shown half of the image is centered on x 2/3.
        let zoomed = Self.metadata.placement(forViewSize: Self.view, imageSize: Self.image, visible: .whole,
                                             user: .init(centerX: 2.0 / 3, centerY: 0.5, zoom: 2))
        #expect(abs(zoomed.contentsRect.width - 0.5) < 1e-9 && abs(zoomed.contentsRect.midX - 2.0 / 3) < 1e-9)
        // Past the edge: slid back to cover the window, never showing past the image.
        let edge = Self.metadata.placement(forViewSize: Self.view, imageSize: Self.image, visible: .whole,
                                           user: .init(centerX: 0, centerY: 1, zoom: 2))
        #expect(edge.contentsRect.minX == 0 && edge.contentsRect.minY == 0 && !edge.fills)
        // Zoom is held to 1...4.
        #expect(BackdropUserPlacement(centerX: 0.5, centerY: 0.5, zoom: 9).zoom == 4)
        #expect(BackdropUserPlacement(centerX: 0.5, centerY: 0.5, zoom: 0.2).zoom == 1)
    }

    @Test func theAutomaticFramingIsTheStartingPoint() {
        let visible = BackdropVisibleSpan(minX: 0.4, maxX: 1)
        let subject = BackdropArtMetadata(focalAnchor: .center, tone: .dark, dominantPalette: [],
                                          quietZone: .init(x: 0, y: 0, width: 0, height: 0),
                                          subjectBox: .init(minX: 0.55, minY: 0.2, maxX: 0.75, maxY: 0.6))
        let automatic = subject.placement(forViewSize: Self.view, imageSize: Self.image, visible: visible)
        let start = subject.userPlacement(from: automatic, viewSize: Self.view, imageSize: Self.image, visible: visible)
        let again = subject.placement(forViewSize: Self.view, imageSize: Self.image, visible: visible, user: start)
        // A drag starts where the art already is: no jump on the first move.
        #expect(abs(again.contentsRect.minX - automatic.contentsRect.minX) < 1e-6)
        #expect(abs(again.contentsRect.width - automatic.contentsRect.width) < 1e-6)
    }

    @Test func placementsPersistByBackgroundAndAnnounceChanges() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("placement-\(UUID().uuidString).json")
        let store = BackdropPlacementStore(file: file)
        let changes = ChangeCount()
        let token = NotificationCenter.default.addObserver(forName: BackdropPlacementStore.didChange, object: store, queue: nil) { _ in
            changes.add()
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let placed = BackdropUserPlacement(centerX: 0.3, centerY: 0.6, zoom: 1.5)
        store.set(placed, for: "starryNight")
        store.set(placed, for: "starryNight")
        #expect(changes.value == 1, "an unchanged placement announced a change")
        #expect(store.placement(for: "starryNight") == placed && store.placement(for: "other") == nil)
        // Saved off the main actor; a new store reads it back.
        let deadline = Date().addingTimeInterval(5)
        while BackdropPlacementStore(file: file).placement(for: "starryNight") == nil, Date() < deadline { usleep(20_000) }
        #expect(BackdropPlacementStore(file: file).placement(for: "starryNight") == placed)
        store.set(nil, for: "starryNight")
        #expect(store.placement(for: "starryNight") == nil && changes.value == 2)
    }
}

/// Counts notifications, which arrive on the posting thread.
nonisolated final class ChangeCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}
