#if DEBUG
import AppKit

extension ChatController {
    /// Agent `peer`'s drawn pill in window coordinates, nil when none shows: a scan of the visible rows'
    /// hit-testing (DEBUG drives and captures click it as a person does).
    func debugAgentPillFrame(_ peer: String) -> CGRect? {
        guard let demo else { return nil }
        let b = host.bounds
        for y in stride(from: b.minY, to: b.maxY, by: 4) {
            for x in stride(from: b.minX, to: b.maxX, by: 8) {
                let p = CGPoint(x: x, y: y)
                guard let hit = demo.hit(p), case let .custom(custom) = hit.row.part,
                      let pill = HomeAgentFoldRowProvider.pill(custom, at: CGPoint(x: p.x - hit.body.minX, y: p.y - hit.body.minY),
                                                               width: hit.body.width),
                      pill.peer == peer else { continue }
                return host.convert(pill.rect.offsetBy(dx: hit.body.minX, dy: hit.body.minY), to: nil)
            }
        }
        return nil
    }
}
#endif
