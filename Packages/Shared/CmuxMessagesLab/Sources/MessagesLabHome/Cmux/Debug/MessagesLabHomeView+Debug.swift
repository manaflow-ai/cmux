import AppKit

#if DEBUG
@MainActor
extension MessagesLabHomeView {
    /// Automation (DEBUG socket): a love tapback on the newest incoming (or,
    /// with `mine`, my newest) message through the picker's path (`ChatIntents.react`).
    public func debugTapbackNewestIncoming(mine: Bool = false) -> Bool {
        guard let hit = controller.demo?.lastTextRow(mine: mine) else { return false }
        projection.react(hit.row.ref, .tapback("love"))
        return true
    }

    /// Automation (DEBUG socket): the context menu at the newest text bubble
    /// (mine or incoming), built by the right-click's path
    /// (`ChatController.menu(at:)`): item titles, "-" for a separator,
    /// "[palette]" for a tapback row.
    public func debugMenuTitles(mine: Bool) -> [String]? {
        guard let hit = controller.demo?.lastTextRow(mine: mine),
              let menu = controller.menu(at: CGPoint(x: hit.body.midX, y: hit.body.midY)) else { return nil }
        controller.menuHighlight?.discard(); controller.menuHighlight = nil // never shown
        return menu.items.map { $0.isSeparatorItem ? "-" : $0.submenu != nil ? "[palette]" : ($0 as? MenuAction)?.label ?? $0.title }
    }

    /// Automation (DEBUG socket): the field's height and, for the newest
    /// receipt row with a row under it, its top to that row's body (macOS 27
    /// Messages: the field is 30 pt after a send and 31 pt from the first key; 20 pt).
    public func debugGeometry() -> [String: Double] {
        guard let demo = controller.demo else { return [:] }
        var out: [String: Double] = ["fieldHeight": Double(demo.compose.fieldRect.height)]
        let rows = demo.model.rows
        // crash program: no index math.
        for (i, row) in rows.enumerated().reversed().dropFirst() where !row.ghost {
            guard case .receipt = row.spec.kind, let next = rows.enumerated().dropFirst(i + 1).first(where: { !$0.element.ghost })?.offset else { continue }
            out["receiptToNextBody"] = Double(demo.layout.contentTop(next) - demo.layout.contentTop(i))
            out["receiptHeight"] = Double(row.spec.height)
            break
        }
        out.merge(debugScaleGeometry()) { $1 }  // the per-view render scale (this debug extension)
        return out
    }

    /// Automation (DEBUG socket): the typing bubble's body (RowCell.typingBody) in window
    /// coordinates (AppKit: origin at the bottom left), nil when no typing row shows.
    public func debugTypingBubbleFrame() -> CGRect? {
        guard let demo = controller.demo, controller.host.window != nil, let hostLayer = controller.host.layer else { return nil }
        for case let cell as RowCell in demo.collection.visibleCells {
            guard case .typing? = cell.spec?.kind, !cell.isHidden else { continue }
            let inHost = cell.typingBody.convert(cell.typingBody.bounds, to: hostLayer)
            return controller.host.convert(inHost, to: nil)
        }
        return nil
    }

    /// Automation (DEBUG socket): the visible rows as drawn, in window coordinates (AppKit: origin
    /// at the bottom left), top to bottom. A message part gives its bubble body (RowDraw.bodyRect in
    /// the row's content, which RowCell.snapRow moves onto the window's device pixels) and its drawn
    /// balloon (RowDraw.balloon: an outgoing text balloon lies a little inside the body on macOS 27);
    /// a thread preview and any other row give the row's content box (both).
    public func debugRowFrames() -> [(kind: String, key: String, outgoing: Bool, frame: CGRect, balloon: CGRect)] {
        guard let demo = controller.demo, controller.host.window != nil, let hostLayer = controller.host.layer else { return [] }
        var rows: [(kind: String, key: String, outgoing: Bool, frame: CGRect, balloon: CGRect)] = []
        for case let cell as RowCell in demo.collection.visibleCells where !cell.isHidden {
            guard let spec = cell.spec else { continue }
            // A row that already left (a ghost fading out, or cut at once) is not on screen.
            if let ip = demo.collection.indexPath(for: cell), demo.model.rows[checked: ip.item]?.ghost == true { continue } // checked
            let content = cell.contentView.layer
            let kind: String, outgoing: Bool, rect: CGRect, drawn: CGRect
            switch spec.kind {
            case let .part(p):
                kind = { if case .text = p.part { return "text" }; return "part" }()
                outgoing = p.outgoing
                rect = RowDraw.bodyRect(spec)
                drawn = RowDraw.balloon(rect, row: p, scale: demo.renderScale)  // this pane's own scale (258b385)
            case .threadPreview(let pv):
                kind = "preview"; outgoing = pv.outgoing
                rect = CGRect(origin: .zero, size: content.bounds.size); drawn = rect
            default:
                kind = "other"; outgoing = false
                rect = CGRect(origin: .zero, size: content.bounds.size); drawn = rect
            }
            func inWindow(_ r: CGRect) -> CGRect { controller.host.convert(content.convert(r, to: hostLayer), to: nil) }
            rows.append((kind, spec.key, outgoing, inWindow(rect), inWindow(drawn)))
        }
        return rows.sorted { $0.frame.maxY > $1.frame.maxY }
    }

    /// Automation (DEBUG socket): MessagesLab's width pass counters (every window view): passes run and
    /// passes deferred to the next display frame (WindowView's resize pacing).
    public var debugWidthPasses: (passes: Int, deferred: Int) {
        (MessagesWindowView.widthPasses, MessagesWindowView.widthPassesDeferred)
    }
    /// MessagesLab's frame budget for width passes (s): a later width change in a display frame runs at once
    /// while that frame's passes cost less (f11642b resize-pace).
    public var debugWidthPassBudget: Double { Double(MessagesWindowView.widthPassFrameBudget) }

    /// The window view's origin in window points (bottom-left origin), for automation.
    public var debugHostOrigin: CGPoint { controller.host.convert(CGPoint.zero, to: nil) }
    /// The window view's frame in window points (bottom-left origin), for automation (its right edge: a pane
    /// whose width is a fraction of a device pixel).
    public var debugHostFrame: CGRect { controller.host.convert(controller.host.bounds, to: nil) }

    /// Automation (DEBUG socket): the text of the newest `limit` messages
    /// this view holds (its own store), oldest first.
    public func debugMessageTexts(limit: Int = 10) -> [String] {
        guard let store = controller.store else { return [] }
        return store.state.conversation.messages.suffix(limit).map { message in
            message.parts.compactMap { part in
                if case let .text(text, _) = part { return text }
                return nil
            }.joined(separator: "\n")
        }
    }

    /// Automation (DEBUG socket): plays or pauses the newest video bubble
    /// through the click's path (`ChatIntents.toggleVideo`).
    public func debugToggleNewestVideo() -> Bool {
        guard let store = controller.store else { return false }
        for m in store.state.conversation.messages.reversed() {
            for (i, part) in m.parts.enumerated() {
                if case let .attachment(a) = part, a.kind == "video" {
                    projection.toggleVideo(PartRef(messageId: m.id, partIndex: i), a.id)
                    return true
                }
            }
        }
        return false
    }

    /// Automation (DEBUG socket): clicks the first shown link whose URL starts with `prefix`,
    /// through the click's path (`ChatController.openLink`, so an app link goes to
    /// `onAppLink`); the clicked URL, or nil when no shown link matches.
    public func debugClickLink(prefix: String) -> String? {
        guard let demo = controller.demo else { return nil }
        let b = controller.host.bounds
        for y in stride(from: b.minY, to: b.maxY, by: 3) {
            for x in stride(from: b.minX, to: b.maxX, by: 3) {
                let p = CGPoint(x: x, y: y)
                guard let url = controller.linkURL(at: p), url.absoluteString.hasPrefix(prefix), let hit = demo.hit(p) else { continue }
                return controller.openLink(hit, at: p) ? url.absoluteString : nil
            }
        }
        return nil
    }

    /// Automation (DEBUG socket): a click on the newest thread's "N Replies" or
    /// thread preview through the click's path (`ChatController.clicked`). The
    /// open thread's root (its transcript id) after the click, nil when none opened.
    public func debugOpenNewestThread() -> String? {
        guard let demo = controller.demo else { return nil }
        let cells = demo.collection.visibleCells.compactMap { $0 as? RowCell }
            .map { $0.convert($0.bounds, to: demo) }.sorted { $0.maxY > $1.maxY }
        for r in cells {
            for y in stride(from: r.maxY, to: r.minY, by: -3) {
                for x in stride(from: r.minX, to: r.maxX, by: 3) {
                    let p = CGPoint(x: x, y: y)
                    guard demo.repliesHit(p) != nil else { continue }
                    controller.clicked(p)
                    return debugOpenThread
                }
            }
        }
        return nil
    }

    /// Automation (DEBUG socket): the open thread's root (its transcript id), nil when none is open.
    public var debugOpenThread: String? { controller.store?.state.ui.openThread?.messageId }

    /// Automation (DEBUG socket): Esc through the field's path (`ChatController.escape`).
    public func debugEscape() { controller.escape() }

    /// Automation (DEBUG socket): Reply… in the context menu at the newest text bubble (mine or
    /// incoming), built and chosen by the right-click's path. The open thread's root after it.
    public func debugReplyNewest(mine: Bool) -> String? {
        guard let hit = controller.demo?.lastTextRow(mine: mine),
              let menu = controller.menu(at: CGPoint(x: hit.body.midX, y: hit.body.midY)) else { return nil }
        controller.menuHighlight?.discard(); controller.menuHighlight = nil // never shown
        guard let item = menu.items.first(where: { ($0 as? MenuAction)?.label == Strings.menuReplyEllipsis }),
              let action = item.action else { return nil }
        NSApp.sendAction(action, to: item.target, from: item)
        return debugOpenThread
    }

    /// Automation (DEBUG socket): a real Esc key press posted to the app's event queue (local
    /// monitors see it), with the key focus on the window itself (`outside`, as when a terminal
    /// or the sidebar has it) or where it is.
    public func debugPostEscape(outside: Bool) {
        guard let window else { return }
        if outside { window.makeFirstResponder(nil) }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                        charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                NSApp.postEvent(e, atStart: false)
            }
        }
    }

    /// Automation (DEBUG socket): scrolls the transcript by `dy` points
    /// through AppKit's scroll view. cmux-classic: within the content (the oldest
    /// loaded row under the header to the pin), as a wheel stops there; the clip
    /// view's `scroll(to:)` does not constrain, and `--dy 2000` showed a blank
    /// transcript past the last row. It chooses a place as the person's scroll does.
    public func debugScroll(by dy: CGFloat) {
        guard let demo = controller.demo else { return }
        let y = Self.clampedScrollOffset(demo.collection.contentOffset.y + dy, min: demo.minOffset, max: demo.pinnedOffset)
        controller.host.scrollView.scroll(toModelOffset: y)
        controller.host.noteChosenPlace()
    }

    /// The pane's render scale and the scale of what its visible rows show, for `debugGeometry`:
    /// `renderScale` (MessagesWindowView.renderScale), `windowScale` (its window's backing scale), `rowBitmaps` (visible
    /// text rows that show a bitmap), `rowBitmapsOffScale` (those whose image is not drawn at the view's scale: its pixel
    /// width is not the layer's point width times `renderScale`, or the layer's contentsScale differs: an old-scale
    /// bitmap), `cellsOffScale` (visible cells whose own renderScale differs), `composeScale`, `headerScale`, and the
    /// least and largest image pixels per layer point of those bitmaps (`bitmapPxPerPtMin`, `bitmapPxPerPtMax`).
    func debugScaleGeometry() -> [String: Double] {
        guard let demo = controller.demo else { return [:] }
        let s = demo.renderScale
        var bitmaps = 0, offScale = 0, cellsOff = 0
        var ratioMin = CGFloat.infinity, ratioMax: CGFloat = 0
        for case let cell as RowCell in demo.collection.visibleCells where !cell.isHidden {
            if cell.renderScale != s { cellsOff += 1 }
            // Text rows only (a media row's placeholder thumbnail is fitted to its bubble, not drawn at the layer's
            // size), and a shown, unstretched bitmap (long text hides it under its tiles).
            guard case let .part(p)? = cell.spec?.kind, case .text = p.part else { continue }
            let layer = cell.bitmap
            guard !layer.isHidden, layer.contentsCenter == CGRect(x: 0, y: 0, width: 1, height: 1),
                  let raw = layer.contents, CFGetTypeID(raw as AnyObject) == CGImage.typeID, layer.bounds.width >= 4 else { continue }
            let image = unsafeDowncast(raw as AnyObject, to: CGImage.self)  // type checked above (ComposeAttachments' pattern)
            bitmaps += 1
            let ratio = CGFloat(image.width) / layer.bounds.width  // image pixels per layer point
            ratioMin = min(ratioMin, ratio); ratioMax = max(ratioMax, ratio)
            // The image is drawn for the layer's size at its scale (ceil to whole pixels); an image from another
            // scale is off by the layer's width times the scale difference (at least 2 px for a 4 pt layer).
            if layer.contentsScale != s || abs(CGFloat(image.width) - layer.bounds.width * s) > s + 0.5 { offScale += 1 }
        }
        return ["renderScale": Double(s), "windowScale": Double(controller.host.window?.backingScaleFactor ?? 0),
                "rowBitmaps": Double(bitmaps), "rowBitmapsOffScale": Double(offScale), "cellsOffScale": Double(cellsOff),
                "composeScale": Double(demo.compose.renderScale), "headerScale": Double(demo.header.layer.contentsScale),
                "bitmapPxPerPtMin": bitmaps > 0 ? Double(ratioMin) : 0, "bitmapPxPerPtMax": Double(ratioMax),
                // The palette state the rows draw with (process-wide) and the window's key state, and whether the
                // bitmaps' colour space is the window screen's (b5742f3 display-change colour check).
                "fixtureInactive": Fixture.inactive ? 1 : 0, "windowKey": (controller.host.window?.isKeyWindow ?? false) ? 1 : 0,
                "appActive": NSApp.isActive ? 1 : 0, "lightAppearance": Fixture.lightAppearance ? 1 : 0,
                "colorSpaceIsScreen": controller.host.window?.screen?.colorSpace?.cgColorSpace.map { $0 == DisplayScale.colorSpace } == true ? 1 : 0]
    }

}
#endif
