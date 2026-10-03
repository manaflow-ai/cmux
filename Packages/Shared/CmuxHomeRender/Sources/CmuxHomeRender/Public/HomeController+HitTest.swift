public import CmuxHomeCore
public import CoreGraphics

/// A message part under a point: what a context menu, a tapback picker or a
/// selection acts on.
public struct HomeHit: Hashable, Sendable {
    /// The transcript item (`TranscriptItem.key`).
    public var item: IdempotencyKey
    public var partIndex: Int
    public var text: String
    public var isMine: Bool
    /// The bubble in viewport points (top-left origin).
    public var bubble: CGRect
}

extension HomeController {
    /// The message bubble under `point` (viewport points, top-left origin).
    public func hit(at hostPoint: CGPoint) -> HomeHit? {
        let point = toDesign(hostPoint)
        let contentY = point.y + scene.offset
        let probe = CGRect(x: point.x, y: contentY - 1, width: 1, height: 2)
        for i in scene.layout.rows(in: probe) where i < scene.model.count {
            let row = scene.model.rows[i]
            guard !row.ghost, row.spec.partRow != nil else { continue }
            let body = RowArt.bodyRect(row.spec, metrics: scene.metrics)
            let top = scene.windowY(contentY: scene.layout.frame(for: i).minY)
            let bubble = body.offsetBy(dx: 0, dy: top)
            guard bubble.contains(point), let hit = hit(forRowKey: row.spec.key, bubble: bubble) else { continue }
            return hit
        }
        return nil
    }

    /// Every message bubble whose vertical span meets `rect` (viewport
    /// points), top to bottom: a drag selection across rows.
    public func hits(in hostRect: CGRect) -> [HomeHit] {
        let rect = toDesign(hostRect)
        let content = rect.offsetBy(dx: 0, dy: scene.offset)
        var out: [HomeHit] = []
        for i in scene.layout.rows(in: CGRect(x: 0, y: content.minY, width: scene.size.width, height: max(1, content.height)))
        where i < scene.model.count {
            let row = scene.model.rows[i]
            guard !row.ghost, row.spec.partRow != nil else { continue }
            let body = RowArt.bodyRect(row.spec, metrics: scene.metrics)
            let bubble = body.offsetBy(dx: 0, dy: scene.windowY(contentY: scene.layout.frame(for: i).minY))
            guard bubble.maxY >= rect.minY, bubble.minY <= rect.maxY,
                  let hit = hit(forRowKey: row.spec.key, bubble: bubble) else { continue }
            out.append(hit)
        }
        return out
    }

    /// Row keys are `part:<item key>:<part index>`.
    private func hit(forRowKey key: String, bubble: CGRect) -> HomeHit? {
        guard key.hasPrefix("part:"), let colon = key.lastIndex(of: ":"),
              let index = Int(key[key.index(after: colon)...]) else { return nil }
        let raw = String(key[key.index(key.startIndex, offsetBy: 5)..<colon])
        guard let item = items.first(where: { $0.key.rawValue == raw }), index < item.parts.count else { return nil }
        return HomeHit(item: item.key, partIndex: index, text: item.parts[index].plainText, isMine: item.author == me,
                       bubble: toHost(bubble))
    }
}
