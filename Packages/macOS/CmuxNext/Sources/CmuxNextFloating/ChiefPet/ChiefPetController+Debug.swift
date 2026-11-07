#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// `debug.chief_pet` (DEBUG and bench builds; `ChiefPetMini.debugMethod()` routes it): the pet driven
/// as a person drives it, for captures. The pet, its notices and its reply box keep `sharingType = .none`
/// (screen shares and recordings leave them out), so a capture cannot shoot them from the screen and the
/// capture driver's clicks and keys reach only the main window: this renders and drives them instead.
///
/// `action`: `state` (the default), `open_reply` (a click on the pet: its reply box), `type` (`text` into
/// the reply field), `send` (Return in the field), `drag` (`dx`, `dy` in points, `steps`, `release`:
/// a press on the character moved through the view's own mouse handlers, so the panel moves and an
/// animated character leans; `release: false` keeps the press for a still mid-drag), `drop` (the press's
/// release), or `snapshot` (`window`: `pet` or `reply`; `path`: a PNG of that panel's layer tree, the
/// character on the frame its animation shows now). Each answers the state after it, or `error`.
extension ChiefPetController {
    public func debug(_ action: String, _ params: [String: Any]) -> [String: Any] {
        if action == "snapshot" { return debugSnapshot(params["window"] as? String ?? "pet", path: params["path"] as? String ?? "") }
        let failure: String? = switch action {
        case "state": nil
        case "open_reply": debugOpenReply()
        case "type": debugType(params["text"] as? String ?? "")
        case "send": debugSend()
        case "drag": debugDrag(dx: params["dx"] as? Double ?? 0, dy: params["dy"] as? Double ?? 0,
                               steps: max(1, min(params["steps"] as? Int ?? 8, 120)), release: params["release"] as? Bool ?? true)
        case "drop": debugDrop()
        default: "unknown action \(action): state, open_reply, type, send, drag, drop or snapshot"
        }
        if let failure { return ["error": failure] }
        return debugState()
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
        }
        if let replyPanel, replyPanel.isVisible {
            state["reply_text"] = replyPanel.field.stringValue
            state["reply_target"] = replyPanel.target.map(ChiefPetReply.title) ?? ""
            if !replyPanel.latestLabel.isHidden { state["reply_latest"] = replyPanel.latestLabel.stringValue }
        }
        return state
    }

    private func debugOpenReply() -> String? {
        guard panel?.isVisible == true else { return "the pet is not shown (home.chiefPetEnabled)" }
        openReply()
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

    /// The panel's layer tree as the render server would draw it now (`render(in:)` draws model values, so the
    /// character's sprite takes the frame its animation shows for the one render, then its model frame again,
    /// within one transaction: nothing on screen changes).
    private func debugSnapshot(_ which: String, path: String) -> [String: Any] {
        guard !path.isEmpty else { return ["error": "pass path"] }
        let window: NSWindow? = which == "reply" ? replyPanel : panel
        guard let window, window.isVisible, let view = window.contentView else { return ["error": "the \(which) panel is not shown"] }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let layer = view.layer else { return ["error": "the \(which) panel has no layer"] }
        let scale = window.backingScaleFactor
        let width = Int((view.bounds.width * scale).rounded()), height = Int((view.bounds.height * scale).rounded())
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return ["error": "no bitmap context"] }
        context.scaleBy(x: scale, y: scale)
        let sprite = window === panel ? panel?.pet.sprite.layer : nil
        let model = sprite?.contents
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let sprite, let now = sprite.presentation()?.contents { sprite.contents = now }
        layer.render(in: context)
        sprite?.contents = model
        CATransaction.commit()
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
}
#endif
