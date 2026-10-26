#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import ObjectiveC
import QuartzCore

extension InputDirtyRecorder {
    /// The input class of a turn's events.
    nonisolated enum TurnKind: UInt8, CaseIterable, Sendable {
        case key, pointer, scroll, gesture

        /// The kind of a person's input event; nil for other events (app-defined, periodic,
        /// cursor updates, tracking-area enter and exit).
        init?(_ type: NSEvent.EventType) {
            switch type {
            case .keyDown, .keyUp, .flagsChanged:
                self = .key
            case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
                 .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .mouseMoved, .pressure:
                self = .pointer
            case .scrollWheel:
                self = .scroll
            case .magnify, .swipe, .rotate, .smartMagnify, .beginGesture, .endGesture:
                self = .gesture
            default:
                return nil
            }
        }

        var bit: UInt8 { 1 << rawValue }
        var key: String { String(describing: self) }
    }

    /// The hooked dirty call.
    nonisolated enum DirtyKind: UInt8, CaseIterable, Sendable {
        case viewNeedsDisplay, viewNeedsDisplayInRect, viewNeedsLayout, viewNeedsUpdateConstraints
        case layerNeedsDisplay, layerNeedsDisplayInRect, layerNeedsLayout

        var bit: UInt8 { 1 << rawValue }

        /// The `debug.input dirty` name.
        var key: String {
            switch self {
            case .viewNeedsDisplay: "view.needsDisplay"
            case .viewNeedsDisplayInRect: "view.setNeedsDisplayInRect"
            case .viewNeedsLayout: "view.needsLayout"
            case .viewNeedsUpdateConstraints: "view.needsUpdateConstraints"
            case .layerNeedsDisplay: "layer.setNeedsDisplay"
            case .layerNeedsDisplayInRect: "layer.setNeedsDisplayInRect"
            case .layerNeedsLayout: "layer.setNeedsLayout"
            }
        }

        /// The class whose own method is hooked.
        var root: AnyClass {
            switch self {
            case .viewNeedsDisplay, .viewNeedsDisplayInRect, .viewNeedsLayout, .viewNeedsUpdateConstraints: NSView.self
            case .layerNeedsDisplay, .layerNeedsDisplayInRect, .layerNeedsLayout: CALayer.self
            }
        }

        var selector: Selector {
            switch self {
            case .viewNeedsDisplay: #selector(setter: NSView.needsDisplay)
            case .viewNeedsDisplayInRect: #selector(NSView.setNeedsDisplay(_:))
            case .viewNeedsLayout: #selector(setter: NSView.needsLayout)
            case .viewNeedsUpdateConstraints: #selector(setter: NSView.needsUpdateConstraints)
            case .layerNeedsDisplay: #selector(CALayer.setNeedsDisplay as (CALayer) -> () -> Void)
            case .layerNeedsDisplayInRect: #selector(CALayer.setNeedsDisplay(_:))
            case .layerNeedsLayout: #selector(CALayer.setNeedsLayout)
            }
        }
    }

    /// When in the turn a dirty call came: during the dispatch, or after it and before the
    /// pass's frame commit ended (the display cycle's layout and display included).
    nonisolated enum Phase: UInt8, CaseIterable, Sendable {
        case dispatch, commit

        var bit: UInt8 { 1 << rawValue }
        var key: String { String(describing: self) }
    }

    /// Where the dirtied view lies against the turn's target view.
    nonisolated enum Placement: UInt8, Sendable, Hashable {
        /// The target or a view in its subtree.
        case inside
        /// Another view of the target's window (or of no window, as the target).
        case outside
        /// A view of another window.
        case otherWindow
        /// A layer no view owns.
        case noView
        /// The event had no target view.
        case noTarget

        /// Work the target's frame did not need.
        var isOffTarget: Bool { self == .outside || self == .otherWindow }

        var key: String {
            switch self {
            case .inside: "inside"
            case .outside: "outside"
            case .otherWindow: "other_window"
            case .noView: "no_view"
            case .noTarget: "no_target"
            }
        }
    }

    /// The dirtied object's view class, layer class (0 for a view's own call) and placement.
    @MainActor
    struct Owner {
        /// A class as its `Class` pointer's bits (the report reads the name back off main).
        let viewClass: UInt
        let layerClass: UInt
        let placement: Placement

        /// The owner of a hooked call's receiver: a view, or a layer and the view that owns it
        /// (its own or an ancestor layer's delegate, at most 32 layers up).
        init(_ object: AnyObject, target: NSView?) {
            if let view = object as? NSView {
                self.init(viewClass: Self.key(view), layerClass: 0, placement: Self.placement(of: view, target: target))
                return
            }
            let view = Self.owningView(of: object as? CALayer)
            self.init(
                viewClass: view.map { Self.key($0) } ?? 0,
                layerClass: Self.key(object),
                placement: view.map { Self.placement(of: $0, target: target) } ?? .noView
            )
        }

        init(viewClass: UInt, layerClass: UInt, placement: Placement) {
            self.viewClass = viewClass
            self.layerClass = layerClass
            self.placement = placement
        }

        private static func owningView(of layer: CALayer?) -> NSView? {
            var next = layer
            var steps = 0
            while let current = next, steps < 32 {
                if let view = current.delegate as? NSView { return view }
                next = current.superlayer
                steps += 1
            }
            return nil
        }

        private static func placement(of view: NSView, target: NSView?) -> Placement {
            guard let target else { return .noTarget }
            if view === target || view.isDescendant(of: target) { return .inside }
            if let window = view.window, let targetWindow = target.window, window !== targetWindow { return .otherWindow }
            return .outside
        }

        /// The dynamic class of `object` as bits (no message sent, nothing allocated).
        private static func key(_ object: AnyObject) -> UInt {
            object_getClass(object).map { unsafeBitCast($0, to: UInt.self) } ?? 0
        }
    }

    /// One site's identity.
    nonisolated struct SiteKey: Hashable, Sendable {
        let viewClass: UInt
        let layerClass: UInt
        let placement: Placement
        let stackHash: Int
    }

    /// One site's counts (its stack lives in the recorder's flat stack table).
    nonisolated struct Site: Sendable {
        let key: SiteKey
        var kinds: UInt8
        var turnKinds: UInt8
        var phases: UInt8
        var count: Int
        var turns: Int
        var lastTurn: Int
        let stackCount: Int
    }

    /// The turn in progress.
    struct OpenTurn {
        let serial: Int
        let began: UInt64
        var kinds: UInt8 = 0
        var events = 0
        /// Dispatches running now (a nested tracking loop dispatches inside one).
        var depth = 0
        var dispatchEnded: UInt64 = 0
        var commitBegan: UInt64 = 0
        var dirtyCalls = 0
        var offTargetCalls = 0
        var target: NSView?
    }

    /// A closed turn.
    nonisolated struct TurnRecord: Sendable {
        let kinds: UInt8
        let events: Int
        let dispatchNanos: UInt64
        /// The pass's `.beforeWaiting` stage: AppKit's display cycle and Core Animation's commit.
        let commitNanos: UInt64
        let dirtyCalls: Int
        let offTargetCalls: Int
    }

    /// The tables copied on the main thread for ``report(limit:)``.
    nonisolated struct Snapshot: Sendable {
        let installed: Bool
        let sites: [Site]
        let stacks: [UInt]
        /// In ring order: slot `turnsClosed % turnLimit` is the oldest once the ring is full.
        let turns: [TurnRecord]
        let turnsClosed: Int
        let droppedCalls: Int
        let dirtyCalls: Int
        let offTargetCalls: Int
        let limit: Int
    }
}
#endif
