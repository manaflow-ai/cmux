import AppKit
import CmuxNextSettings

/// `debug.loops`: every repeating Core Animation animation in the app's windows, and whether
/// anyone can see it (hq#3716). `debug.wakeups` counts main-thread wakeups; a CA loop runs in the
/// render server and never wakes the app, so it needs its own count. A loop is hidden when its
/// window is occluded or a layer or view above it is hidden; `hidden_loops` should be 0.
///
/// `{"limit": N}` lists at most N loops per window (default 50); the counts cover all of them.
/// One walk per call, on the main actor; no timer or observer.
enum DebugLoops {
    static func report(params: [String: JSONValue] = [:]) -> JSONValue {
        let limit = max(0, params["limit"]?.intValue ?? 50)
        var total = 0
        var hidden = 0
        let windows = NSApp.windows.compactMap { window -> JSONValue? in
            guard let root = window.contentView?.superview?.layer ?? window.contentView?.layer else { return nil }
            var loops: [Loop] = []
            collect(root, windowVisible: window.isVisible && window.occlusionState.contains(.visible), into: &loops)
            guard !loops.isEmpty else { return nil }
            total += loops.count
            hidden += loops.filter { !$0.visible }.count
            return .object([
                "window_number": .number(Double(window.windowNumber)),
                "class": .string(String(describing: type(of: window))),
                "loops": .number(Double(loops.count)),
                "hidden_loops": .number(Double(loops.filter { !$0.visible }.count)),
                "items": .array(loops.prefix(limit).map(\.json)),
            ])
        }
        return .object(["loops": .number(Double(total)), "hidden_loops": .number(Double(hidden)), "windows": .array(windows)])
    }

    private struct Loop {
        let key: String
        let layer: String
        let view: String?
        let visible: Bool

        var json: JSONValue {
            .object(["key": .string(key), "layer": .string(layer), "view": view.map(JSONValue.string) ?? .null,
                     "visible": .bool(visible)])
        }
    }

    /// Walks `layer` and its sublayers; `shown` is false once the window or any layer or view on the
    /// way down is hidden or fully transparent.
    private static func collect(_ layer: CALayer, windowVisible shown: Bool, view: NSView? = nil, into loops: inout [Loop]) {
        let owner = (layer.delegate as? NSView) ?? view
        let ownerHidden = (layer.delegate as? NSView)?.isHidden == true
        let shown = shown && !layer.isHidden && layer.opacity > 0 && !ownerHidden
        for key in layer.animationKeys() ?? [] {
            guard let animation = layer.animation(forKey: key), repeats(animation) else { continue }
            loops.append(Loop(key: key, layer: layer.name ?? String(describing: type(of: layer)),
                              view: owner.map { String(describing: type(of: $0)) }, visible: shown))
        }
        for sublayer in layer.sublayers ?? [] { collect(sublayer, windowVisible: shown, view: owner, into: &loops) }
    }

    private static func repeats(_ animation: CAAnimation) -> Bool {
        if animation.repeatCount >= .greatestFiniteMagnitude || animation.repeatDuration > 0 { return true }
        if let group = animation as? CAAnimationGroup { return (group.animations ?? []).contains(where: repeats) }
        return false
    }
}
