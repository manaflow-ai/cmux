public import Foundation

/// Where the person put a background themselves (backgrounds plan phase 6): the point of the
/// image at the center of the visible span, as fractions from its top-left corner, and a zoom
/// past the cover fit. It replaces the automatic subject framing for that background.
public nonisolated struct BackdropUserPlacement: Codable, Equatable, Sendable {
    public var centerX: Double
    public var centerY: Double
    public var zoom: Double

    public static let maximumZoom = 4.0

    public init(centerX: Double, centerY: Double, zoom: Double) {
        let unit = { (value: Double) in min(max(value.isFinite ? value : 0.5, 0), 1) }
        self.centerX = unit(centerX)
        self.centerY = unit(centerY)
        self.zoom = min(max(zoom.isFinite ? zoom : 1, 1), Self.maximumZoom)
    }
}

/// The placements the person set, by background id (`BackdropSelection.id`), kept in
/// `background-placement.json` beside the backgrounds folder. Every window reads it; a change
/// posts ``didChange``.
@MainActor
public final class BackdropPlacementStore {
    public static let shared = BackdropPlacementStore(file: BackdropArtDownloads.defaultFolder.map {
        $0.deletingLastPathComponent().appendingPathComponent("background-placement.json")
    })
    /// Posted (object: the store, userInfo `id`: the background) after a placement changes.
    public static let didChange = Notification.Name("BackdropPlacementStore.didChange")
    /// Saves run one at a time in order, so an older placement never lands after a newer one.
    private nonisolated static let writes = DispatchQueue(label: "cmux.backdrop-placement.save")

    private let file: URL?
    private var placements: [String: BackdropUserPlacement]

    /// `file` nil keeps placements in memory only (tests).
    public init(file: URL?) {
        self.file = file
        // concurrency-allow: one small JSON file read once, when the first window asks
        let data = file.flatMap { try? Data(contentsOf: $0) }
        if let data, let read = try? JSONDecoder().decode([String: BackdropUserPlacement].self, from: data) {
            placements = read
        } else {
            placements = [:]
            // A file that does not read is kept beside, not overwritten by the next save.
            if let file, data != nil {
                // concurrency-allow: one rename of a small unreadable file, once
                try? FileManager.default.moveItem(at: file, to: file.appendingPathExtension("unreadable"))
            }
        }
    }

    public func placement(for id: String) -> BackdropUserPlacement? { placements[id] }

    /// Sets (nil: clears) `id`'s placement and saves the file off the main actor.
    public func set(_ placement: BackdropUserPlacement?, for id: String) {
        guard placements[id] != placement else { return }
        placements[id] = placement
        NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: ["id": id])
        guard let file, let data = try? JSONEncoder().encode(placements) else { return }
        Self.writes.async {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }

    /// Waits for every save queued so far (tests).
    public func flush() {
        Self.writes.sync {}
    }
}

extension BackdropArtMetadata {
    /// The art where the person put it: `user`'s point at the center of the visible span, at
    /// `zoom` times the cover fit, slid back as far as needed to still cover the window.
    public nonisolated func placement(forViewSize viewSize: CGSize, imageSize: CGSize, visible: BackdropVisibleSpan,
                                      user: BackdropUserPlacement) -> BackdropArtPlacement {
        guard viewSize.width > 0, viewSize.height > 0, imageSize.width > 0, imageSize.height > 0 else {
            return .whole(viewSize)
        }
        let (vw, vh) = (Double(viewSize.width), Double(viewSize.height))
        let scale = max(vw / Double(imageSize.width), vh / Double(imageSize.height)) * user.zoom
        let (w, h) = (Double(imageSize.width) * scale, Double(imageSize.height) * scale)
        let middle = (visible.minX + visible.maxX) / 2 * vw
        let x = min(max(middle - user.centerX * w, vw - w), 0)
        let y = min(max(vh / 2 - user.centerY * h, vh - h), 0)
        // The person chose what shows: nothing is measured against a subject.
        let whole = BackdropSubjectBox(minX: 0, minY: 0, maxX: 0, maxY: 0)
        var placed = place(scale: scale, origin: CGPoint(x: x, y: y), viewSize: viewSize, imageSize: imageSize,
                           check: (box: whole, span: -Double.infinity...Double.infinity, height: .infinity))
        placed.keepsSubject = true
        return placed
    }

    /// The user placement that shows what `placement` shows: its center point and zoom, so a
    /// drag starts from the automatic framing on screen.
    public nonisolated func userPlacement(from placement: BackdropArtPlacement, viewSize: CGSize, imageSize: CGSize,
                                          visible: BackdropVisibleSpan) -> BackdropUserPlacement {
        let c = placement.contentsRect, f = placement.frame
        guard f.width > 0, f.height > 0, viewSize.width > 0, viewSize.height > 0, imageSize.width > 0 else {
            return BackdropUserPlacement(centerX: 0.5, centerY: 0.5, zoom: 1)
        }
        // Image fraction at a view point, through the shown part of the image.
        let middleX = (visible.minX + visible.maxX) / 2 * Double(viewSize.width), middleY = Double(viewSize.height) / 2
        let u = c.minX + (middleX - f.minX) / f.width * c.width
        let v = 1 - (c.minY + (middleY - f.minY) / f.height * c.height)
        let scale = f.width / (c.width * imageSize.width)
        let cover = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        return BackdropUserPlacement(centerX: u, centerY: v, zoom: scale / cover)
    }
}
