#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// `debug.chief_pet` (DEBUG and bench builds; `ChiefPetMini.debugMethod()` routes it): the pet driven
/// as a person drives it, for captures. The pet, its notices and its reply box keep `sharingType = .none`
/// (screen shares and recordings leave them out), so a capture cannot shoot them from the screen and the
/// capture driver's clicks and keys reach only the main window: this renders and drives them instead.
///
/// `action`: `state` (the default), `open_reply` (a click on the pet: its reply box; `hold`, default true, keeps
/// it open when it loses the keys, which closes it for a person: in a capture slot the app is never active and
/// another window takes them between two calls), `close_reply`, `type` (`text` into the reply field), `send`
/// (Return in the field), `drag` (`dx`, `dy` in points, `steps`, `release`:
/// a press on the character moved through the view's own mouse handlers, so the panel moves and an
/// animated character leans; `release: false` keeps the press for a still mid-drag), `drop` (the press's
/// release), `motion` (`on`, default true: the frames move as over an active cmux; Reduce Motion still wins), or `snapshot` (`window`: `pet` or `reply`; `path`: a PNG of that panel: its views as AppKit draws
/// them, and the pet's character on the frame its animation shows now; the glass behind them, which only the
/// window server draws, is the window background color). Each answers the state after it, or `error`.
extension ChiefPetController {
    public func debug(_ action: String, _ params: [String: Any]) -> [String: Any] {
        if action == "snapshot" { return debugSnapshot(params["window"] as? String ?? "pet", path: params["path"] as? String ?? "") }
        let failure: String? = switch action {
        case "state": nil
        case "open_reply": debugOpenReply(hold: params["hold"] as? Bool ?? true)
        case "close_reply": debugCloseReply()
        case "type": debugType(params["text"] as? String ?? "")
        case "send": debugSend()
        case "drag": debugDrag(dx: params["dx"] as? Double ?? 0, dy: params["dy"] as? Double ?? 0,
                               steps: max(1, min(params["steps"] as? Int ?? 8, 120)), release: params["release"] as? Bool ?? true)
        case "drop": debugDrop()
        case "motion": debugSetMotion(params["on"] as? Bool ?? true)
        default: "unknown action \(action): state, open_reply, close_reply, type, send, drag, drop, motion or snapshot"
        }
        if let failure { return ["error": failure] }
        return debugState()
    }

    /// Seconds from now until `at` seconds after `motion` turned on (0 once that has passed; nil with no motion on), so a
    /// `snapshot` lands on a chosen moment of the character's loop whatever the caller's latency.
    public func debugWait(untilMotionSeconds at: Double) -> Double? {
        guard let start = debugMotionStart else { return nil }
        return max(0, start + at - CACurrentMediaTime())
    }

    func debugState() -> [String: Any] {
        var state: [String: Any] = [
            "shown": panel?.isVisible == true, "on": isOn, "mascot": mascot.rawValue, "state": drawnState.rawValue,
            "title": home.title, "reply_open": replyPanel?.isVisible == true, "sending": sending,
        ]
        if let chat = home.chat { state["chat"] = ["host": chat.host, "session": chat.session] }
        if let latest = home.latest { state["latest"] = latest }
        if let panel {
            state["frame"] = [panel.frame.minX, panel.frame.minY, panel.frame.width, panel.frame.height].map(Double.init)
            state["pose"] = String(describing: panel.pet.sprite.pose)
            state["moving"] = panel.pet.sprite.isMoving
            state["dragging"] = panel.pet.isDragging
            state["motion"] = debugMotion
            if let start = debugMotionStart { state["motion_seconds"] = CACurrentMediaTime() - start }
        }
        if let replyPanel, replyPanel.isVisible {
            state["reply_text"] = replyPanel.field.stringValue
            state["reply_target"] = replyPanel.target.map(ChiefPetReply.title) ?? ""
            state["reply_key"] = replyPanel.isKeyWindow
            state["reply_held"] = replyPanel.debugHold
            if !replyPanel.latestLabel.isHidden { state["reply_latest"] = replyPanel.latestLabel.stringValue }
        }
        return state
    }

    private func debugOpenReply(hold: Bool) -> String? {
        guard panel?.isVisible == true else { return "the pet is not shown (home.chiefPetEnabled)" }
        // Held before it opens: making it key in an app that is not active can hand the keys straight back,
        // and losing them closes the box before this call returns.
        replyPanelOnce().debugHold = hold
        // A click on the pet (`onClick`, its toggle) when the box is closed.
        openReply()
        guard let replyPanel, replyPanel.isVisible else { return "the reply box did not open" }
        return nil
    }

    private func debugCloseReply() -> String? {
        replyPanel?.debugHold = false
        closeReply()
        return nil
    }

    private func debugType(_ text: String) -> String? {
        guard let replyPanel, replyPanel.isVisible else { return "the reply box is not open (open_reply first)" }
        replyPanel.field.stringValue = text
        return nil
    }

    private func debugSend() -> String? {
        guard let replyPanel, replyPanel.isVisible, let target = replyPanel.target else { return "the reply box is not open (open_reply first)" }
        // Return in the field: the panel's own submit, as `control(_:textView:doCommandBy:)` calls it.
        replyPanel.onSubmit?(target, replyPanel.field.stringValue, false)
        return nil
    }

    private func debugDrag(dx: Double, dy: Double, steps: Int, release: Bool) -> String? {
        guard let panel, panel.isVisible else { return "the pet is not shown (home.chiefPetEnabled)" }
        let view = panel.pet
        view.layoutSubtreeIfNeeded()
        let spot = view.convert(CGPoint(x: view.characterFrame.midX, y: view.characterFrame.midY), to: nil)
        guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: spot, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        else { return "no mouse event" }
        let start: CGPoint
        if let pointer = debugPointer {
            start = pointer
        } else {
            start = panel.convertPoint(toScreen: spot)
            debugPointer = start
            view.pointer = { [weak self] in self?.debugPointer ?? NSEvent.mouseLocation }
            view.mouseDown(with: event)
        }
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            debugPointer = CGPoint(x: start.x + dx * t, y: start.y + dy * t)
            view.mouseDragged(with: event)
        }
        return release ? debugDrop() : nil
    }

    /// `motion` (`on`): the character's frames move as they do over an active cmux, which a capture app never is;
    /// Reduce Motion and the other stop conditions still hold (`characterMoves`).
    private func debugSetMotion(_ on: Bool) -> String? {
        debugMotion = on
        debugMotionStart = on ? CACurrentMediaTime() : nil
        drawCharacter()
        return nil
    }

    private func debugDrop() -> String? {
        guard let panel, debugPointer != nil else { return "no debug drag holds the pet" }
        let view = panel.pet
        if let event = NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) {
            view.mouseUp(with: event)
        }
        debugPointer = nil
        view.pointer = { NSEvent.mouseLocation }
        return nil
    }

    /// The panel as AppKit draws it (`cacheDisplay`), over the window background color where its glass is (the
    /// window server draws glass, which no in-process capture sees), and for the pet its character: the frame
    /// the sprite's animation shows now (its presentation layer), else the still or the upload's first frame.
    private func debugSnapshot(_ which: String, path: String) -> [String: Any] {
        guard !path.isEmpty else { return ["error": "pass path"] }
        let window: NSWindow? = which == "reply" ? replyPanel : panel
        guard let window, window.isVisible, let view = window.contentView else { return ["error": "the \(which) panel is not shown"] }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let scale = window.backingScaleFactor
        let bounds = view.bounds
        let width = Int((bounds.width * scale).rounded()), height = Int((bounds.height * scale).rounded())
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let views = view.bitmapImageRepForCachingDisplay(in: bounds)
        else { return ["error": "no bitmap context"] }
        context.scaleBy(x: scale, y: scale)
        context.interpolationQuality = .none
        let glass: CGRect? = window === panel ? panel.map { $0.pet.rail.frame } : bounds
        if let glass {
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                context.addPath(CGPath(roundedRect: glass, cornerWidth: glass.height / 2, cornerHeight: glass.height / 2, transform: nil))
                // glass-opaque-allow: a DEBUG-only snapshot fills the backing the window server draws as glass, so the still stays readable; it never runs in a release build.
                context.setFillColor(NSColor.windowBackgroundColor.cgColor)
                context.fillPath()
            }
        }
        view.cacheDisplay(in: bounds, to: views)
        if let drawn = views.cgImage { context.draw(drawn, in: bounds) }
        if window === panel, let pet = panel?.pet { Self.drawCharacter(of: pet, in: context) }
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return ["error": "could not write \(path)"] }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return ["error": "could not write \(path)"] }
        var state = debugState()
        state["path"] = path
        state["width"] = width
        state["height"] = height
        return state
    }

    /// The character's frame now, fitted into its box as the layer's `resizeAspect` draws it, mirrored as its row is.
    private static func drawCharacter(of pet: ChiefPetView, in context: CGContext) {
        let sprite = pet.sprite.layer
        let shown = sprite.presentation() ?? sprite
        var mirrored = false
        let image: CGImage?
        if !sprite.isHidden, let contents = shown.contents ?? sprite.contents {
            image = cgImage(contents)
            mirrored = shown.affineTransform().a < 0
        } else {
            image = pet.characterContents.flatMap(cgImage)
        }
        guard let image, image.width > 0, image.height > 0 else { return }
        let box = pet.characterFrame
        let fit = min(box.width / CGFloat(image.width), box.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * fit, height: CGFloat(image.height) * fit)
        let rect = CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height)
        context.saveGState()
        if mirrored {
            context.translateBy(x: rect.midX * 2, y: 0)
            context.scaleBy(x: -1, y: 1)
        }
        context.draw(image, in: rect)
        context.restoreGState()
    }

    /// A layer's contents as a CGImage: a CGImage, or an NSImage's.
    private static func cgImage(_ contents: Any) -> CGImage? {
        if let image = contents as? NSImage { return image.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        let object = contents as AnyObject
        guard CFGetTypeID(object) == CGImage.typeID else { return nil }
        return unsafeBitCast(object, to: CGImage.self)
    }
}
#endif
