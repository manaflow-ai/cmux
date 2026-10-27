public import CmuxAgentCursor
public import CmuxNextDesign
public import QuartzCore

/// Draws agent cursors as CALayers inside one host layer: the window's
/// `OverlayPlane` layer (y-down, layout-root coordinates, kept above
/// Chromium pages by `WindowOverlayLayer`). Travel is one keyframe animation
/// per action on the render server; there is no timer and no per-frame work
/// here, and nothing runs while no agent acts.
public final class AgentCursorLayerHost: AgentCursorLayerHosting {
    /// Fill color per session. The App passes `AgentCursorPalette.forSession`
    /// once the vendored package carries it (cmux-cua v0.8.3).
    public typealias Coloring = (String) -> CGColor
    /// The name tag text per session (``AgentCursorSessionLabel``); nil or
    /// empty shows no tag.
    public typealias Labeling = (String) -> String?

    /// How long a cursor stays after its agent's last action: the cmux-cua
    /// helper's idle fade (`--idle-hide-ms 10000`, cx-ujus), so in-app and
    /// screen cursors leave together.
    public static let idleHideDelay: CFTimeInterval = 10

    private let hostLayer: CALayer
    /// The window's glass mask layer: each cursor's blur shapes go here.
    private let glassLayer: CALayer?
    private let color: Coloring
    private let label: Labeling
    /// Reduce Transparency: the tags draw opaque while it is on.
    private let reduceTransparency: ReduceTransparency
    private var cursors: [String: AgentCursorLayer] = [:]
    /// A cursor came, went, showed or hid: the window's tag links may have
    /// changed (`WindowOverlayHost.agentCursorTagsDidChange`).
    public var onTagsChange: (() -> Void)?

    public init(hostLayer: CALayer, glassLayer: CALayer? = nil, color: @escaping Coloring,
                label: @escaping Labeling = { AgentCursorSessionLabel(sessionID: $0).text },
                reduceTransparency: ReduceTransparency = .shared) {
        self.hostLayer = hostLayer
        self.reduceTransparency = reduceTransparency
        self.glassLayer = glassLayer
        self.color = color
        self.label = label
    }

    /// Sessions with a cursor layer, sorted (diagnostics).
    public var sessions: [String] {
        cursors.keys.sorted()
    }

    /// The cursor layer of a session (tests and diagnostics).
    public func cursorLayer(for session: String) -> AgentCursorLayer? {
        cursors[session]
    }

    public func apply(_ command: AgentCursorCommand) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // Reduce Transparency may have changed since the last action; a no-op when it did not.
        for cursor in cursors.values { cursor.reducesTransparency = reduceTransparency.isEnabled }
        switch command {
        case let .place(session, point):
            let cursor = cursor(for: session)
            for layer in cursor.roots { layer.position = point }
            cursor.layOutTag(tip: point)
            for layer in cursor.roots { layer.isHidden = false }
            cursor.showsIndicator = false
            cursor.armIdleHide(after: Self.idleHideDelay)
        case let .glide(session, plan):
            let cursor = cursor(for: session)
            for layer in cursor.roots { layer.isHidden = false }
            cursor.showsIndicator = false
            if let last = plan.samples.last {
                let end = CGPoint(x: last.x, y: last.y)
                for layer in cursor.roots { layer.position = end }
                // The tag rides with the arrow, laid out for where the glide ends.
                cursor.layOutTag(tip: end)
                for layer in cursor.headings {
                    layer.setValue(last.heading - AgentCursorOverlayModel.restingHeading, forKeyPath: "transform.rotation.z")
                }
            }
            // The cmux-cua path, played short (user, 2026-10-20: "quick:
            // short, snappy motion"), through the Motion gate: at once under
            // Reduce Motion or with animations off.
            let played = Motion.cursor.agentCursorGlideDuration(plan.duration) ?? 0
            cursor.lastGlideDuration = played
            if played > 0 {
                let position = plan.positionAnimation()
                position.duration = played
                let rotation = plan.rotationAnimation()
                rotation.duration = played
                rotation.values = rotation.values?.compactMap { ($0 as? Double).map { $0 - AgentCursorOverlayModel.restingHeading } }
                for layer in cursor.roots { layer.add(position, forKey: "agentCursor.glide") }
                for layer in cursor.headings { layer.add(rotation, forKey: "agentCursor.heading") }
            } else {
                for layer in cursor.roots { layer.removeAnimation(forKey: "agentCursor.glide") }
                for layer in cursor.headings { layer.removeAnimation(forKey: "agentCursor.heading") }
            }
            cursor.armIdleHide(after: played + Self.idleHideDelay)
        case let .confine(session, bounds):
            cursor(for: session).confinement = bounds
        case let .pulse(session):
            // A pulse follows its action's place or glide, which armed the idle hide.
            cursor(for: session).pulse()
        case let .caption(session, text):
            // Only a placed cursor shows a caption (the model checks it);
            // typing keeps the cursor up as any input does.
            guard let cursor = cursors[session] else { return }
            cursor.showCaption(text, scale: max(hostLayer.contentsScale, 2))
            cursor.armIdleHide(after: Self.idleHideDelay)
        case let .indicate(session, anchor):
            let cursor = cursor(for: session)
            for layer in cursor.headings { layer.removeAnimation(forKey: "agentCursor.heading") }
            for layer in cursor.roots {
                layer.removeAnimation(forKey: "agentCursor.glide")
                layer.position = anchor
                layer.isHidden = false
            }
            cursor.showsIndicator = true
            cursor.armIdleHide(after: Self.idleHideDelay)
        case let .hide(session):
            for layer in cursors[session]?.roots ?? [] { layer.isHidden = true }
        case let .setPaused(session, paused):
            // Never create a cursor for a pause: lease frames reach every
            // content, and the model refuses input while paused anyway.
            cursors[session]?.isPaused = paused
        case let .remove(session):
            for layer in cursors.removeValue(forKey: session)?.roots ?? [] { layer.removeFromSuperlayer() }
        }
        switch command {
        case .place, .glide, .indicate, .hide, .remove: onTagsChange?()
        case .pulse, .caption, .setPaused, .confine: break
        }
    }

    /// The name tags a person can click now, by session, in the host
    /// layer's coordinates: shown cursors with a tag, not faded out after
    /// their agent went idle. A gliding tag is where it is drawn now.
    public func tagSpots() -> [AgentCursorTagSpot] {
        cursors.keys.sorted().compactMap { session in
            guard let cursor = cursors[session], cursor.hasName, !cursor.root.isHidden, !cursor.showsIndicator,
                  !cursor.nameTag.isHidden else { return nil }
            var position = cursor.root.position
            if cursor.root.animation(forKey: "agentCursor.glide") != nil, let shown = cursor.root.presentation() {
                position = shown.position
            }
            if cursor.root.animation(forKey: AgentCursorLayer.idleHideKey) != nil, let shown = cursor.root.presentation(),
               shown.opacity < 0.05 {
                return nil
            }
            return AgentCursorTagSpot(session: session, frame: cursor.nameTag.frame.offsetBy(dx: position.x, dy: position.y))
        }
    }

    /// Highlights the tag of `session` (the pointer is on it); nil highlights none.
    public func highlightTag(of session: String?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (key, cursor) in cursors { cursor.isTagHighlighted = key == session }
        CATransaction.commit()
    }

    private func cursor(for session: String) -> AgentCursorLayer {
        if let existing = cursors[session] {
            return existing
        }
        let cursor = AgentCursorLayer(color: color(session), name: label(session), scale: max(hostLayer.contentsScale, 2))
        cursor.reducesTransparency = reduceTransparency.isEnabled
        hostLayer.addSublayer(cursor.root)
        glassLayer?.addSublayer(cursor.glassRoot)
        cursors[session] = cursor
        return cursor
    }
}
