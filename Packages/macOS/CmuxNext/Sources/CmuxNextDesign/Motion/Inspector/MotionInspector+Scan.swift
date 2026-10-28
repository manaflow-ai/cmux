public import AppKit
public import QuartzCore

/// Finding the animations no Motion gate helper made (Lawrence's brief: "any animation that does not
/// go through the gate is a finding: list it, do not patch around it").
extension MotionInspector {
    /// Walks every window's layer tree once and returns the animations on screen that carry no gate tag
    /// (``tagKey``) and match no gate transaction that runs now (a gate `transaction` makes Core Animation
    /// build its implicit actions, untagged, with the transaction's duration). A gate-made animation found
    /// on a layer names its record's owner type. On demand only (the window's Scan, `debug.motion`
    /// `findings`): never per frame.
    @discardableResult
    public func scan() -> [MotionInspectorFinding] {
        let began = CACurrentMediaTime()
        let at = motionNow
        // Untagged animations a gate group made: Core Animation builds them for a gate transaction's implicit
        // actions and AppKit for a gate `animator()` group on a layer-backed view, with the group's duration.
        let groups = records.filter { $0.isRunning && ($0.property == "implicit" || $0.runs == .appKit) }
        let groupSeconds = groups.compactMap(\.curve.seconds)

        var found: [MotionInspectorFinding] = []
        var seen = Set<MotionInspectorFinding>()
        var owners: [UInt64: String] = [:]
        var layers = 0
        func visit(_ layer: CALayer) {
            layers += 1
            for key in layer.animationKeys() ?? [] {
                guard let animation = layer.animation(forKey: key) else { continue }
                if let id = (animation.value(forKey: Self.tagKey) as? NSNumber)?.uint64Value {
                    owners[id] = Self.ownerType(of: layer)
                    continue
                }
                let owner = Self.ownerType(of: layer)
                if groupSeconds.contains(where: { abs($0 - animation.duration) < 0.001 }) { continue }
                let finding = MotionInspectorFinding(
                    ownerType: owner, key: key,
                    property: (animation as? CAPropertyAnimation)?.keyPath ?? (animation as? CATransition).map { $0.type.rawValue } ?? "?",
                    animationClass: String(describing: type(of: animation)), seconds: animation.duration,
                    repeats: curve(of: animation).seconds == nil,
                    appKitOwned: owner.hasPrefix("NS") || owner.hasPrefix("_NS"))
                if seen.insert(finding).inserted { found.append(finding) }
            }
            if let mask = layer.mask { visit(mask) }
            for sublayer in layer.sublayers ?? [] { visit(sublayer) }
        }
        for window in windows() where window.isVisible {
            if let root = Self.rootLayer(of: window) { visit(root) }
        }
        var updated = records
        for index in updated.indices {
            if updated[index].ownerType == nil, let owner = owners[updated[index].id] { updated[index].ownerType = owner }
        }
        // A loop has no end of its own: it ends when no visible layer carries it any more (a loop in a hidden
        // window ends here too; it starts again, as a new record, when its layer shows).
        for index in updated.indices where updated[index].isRunning && updated[index].curve.seconds == nil
            && updated[index].runs == .renderServer && owners[updated[index].id] == nil {
            updated[index].ended = at
        }
        if updated != records { records = updated }
        findings = found
        overhead.addScan((CACurrentMediaTime() - began) * 1000, layers: layers)
        return found
    }

    /// Motion a layer scan cannot see, from the 2026-10-27 inventory (motion-first-principles.md,
    /// plans/cmux-next/motion-inspector.md): each either does not slow with the time scale or is not
    /// made by a gate helper. `site` is the code location; `note` says what it does under the inspector.
    public struct StaticFinding: Sendable, Equatable {
        public var site: String
        public var note: String
    }

    /// The bypasses a scan cannot find. The fleet's slow-motion test (MotionInspectorSlowMotionTests)
    /// measures the gate paths; these are outside every gate path.
    public static let staticFindings: [StaticFinding] = [
        StaticFinding(site: "webviews/src/scrollers.ts:84",
                      note: "requestAnimationFrame ink fade: not a CSS or Web Animations animation, does not slow"),
        StaticFinding(site: "webviews/src/agent-session/acpmux/conversation/RevealedMarkdown.tsx:14",
                      note: "requestAnimationFrame streaming reveal and pacing: keeps its own pace, does not slow"),
        StaticFinding(site: "webviews/src/ui/glass/lens.ts:11", note: "requestAnimationFrame WebGL lens: does not slow"),
        StaticFinding(site: "CmuxNextDesign/Windows/WindowZoom.swift:50",
                      note: "NSWindow frame in an AppKit timed group: AppKit's own timer, lengthened at start only"),
        StaticFinding(site: "CmuxNextFloating/QuickComposer/QuickComposerPanel+Floating.swift:55",
                      note: "NSWindow frame in an AppKit timed group: AppKit's own timer, lengthened at start only"),
        StaticFinding(site: "AppKit (menus, sheets, full screen, NSScrollView elastic scroll, NSPopover)",
                      note: "AppKit-owned motion outside every switch"),
        StaticFinding(site: "CmuxNextDesign/Motion/MotionPath.swift:94",
                      note: "samples render-server paths at media time: a follower built from it (tab strip insets) "
                          + "keeps real-time keyframe spacing while slowed"),
        StaticFinding(site: "CmuxNextTabs/TabCell.swift:190, TabCell+AudioBadge.swift:30, TabCell+LazyLayers.swift:42, "
                          + "Groups/TabGroupChipCell.swift:69",
                      note: "implicit layer actions with a 0 s gate action: a write outside Motion.tabs.transaction "
                          + "would take Core Animation's 0.25 s default (the scan lists one if it happens)"),
    ]
}
