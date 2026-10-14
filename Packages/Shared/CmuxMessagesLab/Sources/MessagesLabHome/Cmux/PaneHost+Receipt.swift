import AppKit

// cmux: MessagesLab 64af10f Host.swift's `prefetchNextReceipt` (not vendored), for the pane controller.

extension ChatController {
    /// The next receipt row of my newest message, drawn ahead on RowBitmaps' loader queue (off the
    /// main thread): "Delivered" once it is sent, "Read <this minute>" once it is delivered. When the
    /// status comes (Home: HomeDiff's status from HomeStore), the cell finds the bitmap in the cache;
    /// before, the cell drew it on the main thread in that commit (rig take 511: 0.35 to 0.5 ms of
    /// glyph rasterization on the receipt's frame). The spec is the one Layout makes for the row
    /// (key, kind, gap 0, height 16, the transcript width), so the pixels are the same; when the
    /// status differs (another minute, a failure) or the width changed, the row misses the cache and
    /// is drawn as before. Called after every engine change (afterEngine).
    func prefetchNextReceipt() {
        guard let store, let demo else { return }
        let state = store.state
        guard let m = state.conversation.messages.last, m.senderId == state.me else { return }
        let step: Int
        switch m.status { case .sending?, .sent?: step = 0; case .delivered?: step = 1; default: return }
        if let a = receiptAhead, a.0 == m.id, a.1 == step { return }
        guard let part = demo.model.rows.last(where: { $0.spec.key.hasPrefix("part:\(m.id):") }) else { return }
        receiptAhead = (m.id, step)
        let key = "receipt:\(m.id)", width = part.spec.width, now = store.date(at: clock)
        func ask(_ kind: RowSpec.Kind) {
            var spec = RowSpec(key: key, kind: kind, gap: 0, height: 16)
            spec.width = width
            let scale = demo.renderScale
            if !RowBitmaps.shared.has(spec, scale: scale) { RowBitmaps.shared.request(spec, scale: scale) }
        }
        if step == 0 { ask(.receipt(bold: Strings.delivered, rest: "")); return }
        // The time text (ICU, 0.1 to 0.3 ms) is made off the main thread too.
        DispatchQueue.global(qos: .userInitiated).async {
            let rest = "\u{00A0}" + Format.time(now)
            DispatchQueue.main.async { ask(.receipt(bold: Strings.read, rest: rest)) }
        }
    }
}
