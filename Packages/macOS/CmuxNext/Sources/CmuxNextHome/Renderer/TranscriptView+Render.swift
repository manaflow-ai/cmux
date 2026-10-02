import AppKit
import CmuxNextDesign
import QuartzCore

extension TranscriptView {
    /// Places every row near the viewport at its target frame, commits the
    /// motion components of the latest event, recycles layers and prefetches
    /// bitmaps. Runs on events only.
    func render() {
        guard window != nil, bounds.height > 0 else { return }
        let started = CACurrentMediaTime()
        let t = started
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer {
            CATransaction.commit()
            onRender?((CACurrentMediaTime() - started) * 1000)
        }
        let h = bounds.height
        measureNearViewport(base: contentBase(), height: h)
        let base = contentBase()
        lastBase = base
        let rows = rowLayout.rows, tops = rowLayout.tops
        let margin = h
        let first = rowLayout.lowerBound { base + tops[$0] + rows[$0].height >= -margin }
        let last = rowLayout.lowerBound { base + tops[$0] > h + margin }
        var list: [(row: TranscriptRow, rect: CGRect)] = []
        list.reserveCapacity(max(0, last - first))
        for index in first..<max(first, last) {
            let row = rows[index]
            let top = (base + tops[index]).rounded(.down)
            list.append((row, CGRect(x: row.x, y: top, width: row.width, height: row.height)))
        }
        commitEventMotion(list: list)
        committedTop = Dictionary(list.map { ($0.row.key, $0.rect.minY) }, uniquingKeysWith: { a, _ in a })
        dropFinishedMotion(at: t)
        prefetchRasters(base: base, height: h)

        // a fast scroll (a quarter screen per event) shows plain shapes for rows not drawn yet
        let fast = abs(scrollVelocity) >= h / 4
        let pad = RowPainter.pad(geometry)
        var used = Set<String>()
        var placeholders = 0
        var targets: [String: CGRect] = [:]
        for entry in list {
            let key = entry.row.key
            let motion = rowMotion[key] ?? []
            let reach = motion.reach
            guard entry.rect.maxY + reach > -pad, entry.rect.minY - reach < h + pad else { continue }
            let layer = live[key] ?? dequeue(key)
            let rasterKey = RasterKey(row: entry.row, geometry: geometry, colors: colors, scale: scale)
            if layer.rasterKey != rasterKey || layer.isPlaceholder {
                configure(layer, row: entry.row, key: rasterKey, placeholderOK: fast && motion.isEmpty, pad: pad)
            }
            if layer.isPlaceholder { placeholders += 1 }
            used.insert(key)
            targets[key] = entry.rect
            layer.frame = layerFrame(entry.rect.insetBy(dx: -pad, dy: -pad))
            layer.isHidden = false
            committer.attach(motion, to: layer, keyPath: "position.y", scale: -1, now: t, tag: layer.motionTag)
            committer.attach(rowFade[key] ?? [], to: layer, keyPath: "opacity", scale: 1, now: t, tag: layer.motionTag)
        }
        placeholdersShown += placeholders
        rasterizer.placeholdersOnScreen(placeholders > 0)
        for (key, layer) in live where !used.contains(key) {
            live[key] = nil
            layer.reset()
            layer.isHidden = true
            if pool.count < 24 { pool.append(layer) } else { layer.removeFromSuperlayer() }
        }
        maxLiveLayers = max(maxLiveLayers, live.count)
        renderFlights(targets: targets, now: t)
        scheduleCleanup(now: t)
        reportNewestSeen(base: base)
        checkPaging()
    }

    private func dequeue(_ key: String) -> RowLayer {
        let layer = pool.popLast() ?? RowLayer.make()
        if layer.superlayer == nil { contentLayer.addSublayer(layer) }
        live[key] = layer
        return layer
    }

    private func configure(_ layer: RowLayer, row: TranscriptRow, key: RasterKey, placeholderOK: Bool, pad: CGFloat) {
        if let image = rasterizer.image(key) {
            layer.show(image, row: row, key: key, geometry: geometry)
        } else if placeholderOK {
            layer.showPlaceholder(row: row, key: key, pad: pad, geometry: geometry)
            rasterizer.prefetch([job(row, key: key)])
        } else if let image = rasterizer.drawNow(job(row, key: key)) {
            layer.show(image, row: row, key: key, geometry: geometry)
        }
    }

    func job(_ row: TranscriptRow, key: RasterKey) -> RasterJob {
        RasterJob(key: key, row: row, geometry: geometry, colors: colors, scale: scale, space: colorSpace)
    }

    /// Rows from two screens above to three below are drawn ahead, further in the scroll direction.
    private func prefetchRasters(base: CGFloat, height h: CGFloat) {
        let ahead = min(8 * h, 6 * abs(scrollVelocity))
        let top = -2 * h - (scrollVelocity > 0 ? ahead : 0)
        let bottom = 3 * h + (scrollVelocity < 0 ? ahead : 0)
        let rows = rowLayout.rows, tops = rowLayout.tops
        let from = rowLayout.lowerBound { base + tops[$0] + rows[$0].height >= top }
        let to = rowLayout.lowerBound { base + tops[$0] > bottom }
        guard from < to else { return }
        rasterizer.prefetch(rows[from..<to].map { job($0, key: RasterKey(row: $0, geometry: geometry, colors: colors,
                                                                            scale: scale)) })
    }

    /// Measures estimated rows within two screens of the viewport. The anchor
    /// keeps what is on screen in place while heights change.
    private func measureNearViewport(base: CGFloat, height h: CGFloat) {
        guard !rowLayout.isEmpty else { return }
        let rows = rowLayout.rows, tops = rowLayout.tops
        let from = rowLayout.lowerBound { base + tops[$0] + rows[$0].height >= -2 * h }
        let to = rowLayout.lowerBound { base + tops[$0] > 3 * h }
        guard from < to else { return }
        _ = rowLayout.measure(rows: from..<to, measurer: measurer, geometry: geometry)
    }

    /// One component per row that changed place since its last commit, all
    /// with the event's timing (one shared motion, like a batch update).
    private func commitEventMotion(list: [(row: TranscriptRow, rect: CGRect)]) {
        guard let event = pendingEvent else { return }
        pendingEvent = nil
        var deltas: [CGFloat?] = list.map { entry in committedTop[entry.row.key].map { $0 - entry.rect.minY } }
        // new rows move with their neighbours
        for i in deltas.indices where deltas[i] == nil {
            deltas[i] = deltas[(i + 1)...].first { $0 != nil } ?? deltas[..<i].last { $0 != nil } ?? nil
        }
        for (i, entry) in list.enumerated() {
            guard let delta = deltas[i] ?? nil, abs(delta) > 0.01 else { continue }
            rowMotion[entry.row.key, default: []].append(committer.make(start: event.time, delta: delta,
                                                                       timing: event.timing))
        }
        for (key, flight) in flights {
            guard let slot = list.first(where: { $0.row.key == key })?.rect else { continue }
            let delta = flight.slot.minY - slot.minY
            if abs(delta) > 0.01 { flight.retarget(dy: delta, at: event.time, timing: event.timing, slot: slot) }
        }
    }

    private func dropFinishedMotion(at t: Double) {
        for (key, components) in rowMotion {
            let remaining = components.filter { !$0.done(at: t) }
            rowMotion[key] = remaining.isEmpty ? nil : remaining
        }
        for (key, components) in rowFade {
            let remaining = components.filter { !$0.done(at: t) }
            rowFade[key] = remaining.isEmpty ? nil : remaining
        }
    }

    /// One render after the last motion ends (drops finished flights and components).
    private func scheduleCleanup(now t: Double) {
        var end = -1.0
        for components in rowMotion.values { end = max(end, components.end) }
        for components in rowFade.values { end = max(end, components.end) }
        for flight in flights.values { end = max(end, flight.end) }
        guard end > t else { return }
        cleanup.schedule(after: .milliseconds(Int(((end - t) * 1000).rounded(.up)) + 16)) { @MainActor [weak self] in
            self?.render()
        }
    }

    private func reportNewestSeen(base: CGFloat) {
        guard history.atNewest, history.lastSeq > lastSawNewest, let onSawNewest,
              let lastConfirmed = (0..<history.count).last(where: { history[$0].seq != nil }) else { return }
        let key = history[lastConfirmed].rowKey
        guard let start = rowLayout.messageStarts.indices.contains(lastConfirmed) ? rowLayout.messageStarts[lastConfirmed] : nil,
              start < rowLayout.tops.count, base + rowLayout.tops[start] < viewportBottom else { return }
        _ = key
        lastSawNewest = history.lastSeq
        onSawNewest(history.lastSeq)
    }
}
