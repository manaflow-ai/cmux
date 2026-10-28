public import Foundation
public import CmuxNextDesignTokens

/// One animation the Motion Inspector saw start (``MotionInspector/records``): what moves, on which
/// curve, where it runs, and what it cost while it ran. Times are seconds of animation time since
/// the inspection started (``MotionInspector/motionNow``): they stand still while paused and run
/// at the time scale's rate, so a 120 ms fade reads 120 ms at every scale.
public nonisolated struct MotionInspectorRecord: Sendable, Equatable, Identifiable {
    /// Where the animation's frames are made.
    public enum Runs: String, Sendable {
        /// Core Animation on the render server: no main-thread work per frame.
        case renderServer = "render_server"
        /// A cmux CPU spring stepped on the main thread each frame (``MotionClock``).
        case main
        /// AppKit steps an `animator()` change on the main thread (an `NSAnimationContext` group).
        case appKit = "appkit"
    }

    /// The timing curve.
    public enum Curve: Sendable, Equatable {
        /// A spring: response and damping fraction (SwiftUI terms) and its perceived duration
        /// (the last visible pixel, ``SpringParameters/perceivedDuration``).
        case spring(response: Double, damping: Double, perceived: Double)
        /// A timed curve of `seconds` (`name`: the timing function, "linear" for sampled keyframes).
        case timed(seconds: Double, name: String)
        /// A repeating loop of `period` seconds, with no end.
        case loop(period: Double)
        /// Stepped per frame by its owner (a CPU spring): its curve is the owner's.
        case stepped

        /// Seconds the curve runs (nil for a loop or a stepped animation).
        public var seconds: Double? {
            switch self {
            case .spring(_, _, let perceived): perceived
            case .timed(let seconds, _): seconds
            case .loop, .stepped: nil
            }
        }
    }

    public let id: UInt64
    /// The call site that started it (`Module/File.swift:line`), when a gate entry point named it.
    public var site: String?
    /// The type that owns the animated layer or view (a layer's delegate), when known.
    public var ownerType: String?
    /// The gate's category; nil when the animation was made below the entry points (a tab move,
    /// an attention flash) and no entry point named one.
    public var category: MotionCategory?
    /// What started it: `layer.opacity`, `render.move`, `appkit.fadeIn`, `clock.layout`, `loop.spin` ...
    public var kind: String
    /// The animated key path ("opacity", "position", "bounds.size"); "animator()" for an AppKit group.
    public var property: String
    public var from: String?
    public var to: String?
    public var curve: Curve
    public var runs: Runs
    /// Made by a Motion gate helper (false only for a scan finding).
    public var gated: Bool
    /// Started, in animation seconds since the inspection began.
    public var start: Double
    /// When its curve ends, in animation seconds; nil for a loop or a stepped animation.
    public var expectedEnd: Double?
    /// When it ended (its completion ran, its curve ran out, or its clock let it rest); nil while running.
    public var ended: Double?
    /// The action it answers (``MotionInspector/Intent``), and whether it was matched by the run's input (true)
    /// or by the time window after the action (false); nil when no action was running.
    public var intent: UInt64?
    public var intentExact = false
    /// Media time it started (wall clock, for the one-intent check: animation times stand still while paused).
    public var wallStart: CFTimeInterval = 0
    /// Layers it moves: one call that animates several layers alike in one turn (a sidebar insert moves
    /// every row below it) is one record.
    public var layers: Int = 1
    /// Display frames the main thread saw while it ran (inspector frame ticks).
    public var frames: Int = 0
    /// Display refreshes in that span with no main-thread frame: drops the main thread caused.
    public var droppedFrames: Int = 0
    /// Main-thread milliseconds of its own per-frame steps (CPU springs only): count, sum and largest.
    public var mainFrames: Int = 0
    public var mainTotalMs: Double = 0
    public var mainMaxMs: Double = 0

    public var isRunning: Bool { ended == nil }
    /// Mean main-thread milliseconds per stepped frame; nil when it has none.
    public var mainMeanMs: Double? { mainFrames > 0 ? mainTotalMs / Double(mainFrames) : nil }
    /// `site`, else the owner type, else "?": the owner column.
    public var owner: String {
        [site, ownerType].compactMap { $0 }.joined(separator: " ").nilIfEmpty ?? "?"
    }

    public init(id: UInt64, site: String?, ownerType: String?, category: MotionCategory?, kind: String, property: String,
                from: String?, to: String?, curve: Curve, runs: Runs, gated: Bool, start: Double, expectedEnd: Double?) {
        self.id = id
        self.site = site
        self.ownerType = ownerType
        self.category = category
        self.kind = kind
        self.property = property
        self.from = from
        self.to = to
        self.curve = curve
        self.runs = runs
        self.gated = gated
        self.start = start
        self.expectedEnd = expectedEnd
    }
}

/// An animation on screen that no Motion gate helper made (``MotionInspector/scan()``): it does not
/// obey the master switch, its category switch, `ui.animationSpeed` or Reduce Motion unless its owner
/// checks them itself. The root time base still slows a Core Animation one; ``MotionInspector/staticFindings``
/// lists the kinds that do not slow at all.
public nonisolated struct MotionInspectorFinding: Sendable, Equatable, Hashable {
    /// The animated layer's owner: its delegate's type, else the layer's class.
    public var ownerType: String
    /// The animation's key on the layer.
    public var key: String
    public var property: String
    /// The animation's class (CABasicAnimation, CASpringAnimation, ...).
    public var animationClass: String
    public var seconds: Double
    public var repeats: Bool
    /// Made by AppKit itself (an `NS` class owns the layer): outside every switch by design.
    public var appKitOwned: Bool

    public init(ownerType: String, key: String, property: String, animationClass: String, seconds: Double, repeats: Bool,
                appKitOwned: Bool) {
        self.ownerType = ownerType
        self.key = key
        self.property = property
        self.animationClass = animationClass
        self.seconds = seconds
        self.repeats = repeats
        self.appKitOwned = appKitOwned
    }
}

/// What the inspector itself costs on the main thread while it inspects (none while it does not):
/// each start it records, each frame tick it counts, each layer-tree scan and each window render.
public nonisolated struct MotionInspectorOverhead: Sendable, Equatable {
    /// Most recent per-frame costs (tick plus the window's render that frame), milliseconds.
    public private(set) var frameMs: [Double] = []
    public private(set) var notes = 0
    public private(set) var noteTotalMs = 0.0
    public private(set) var noteMaxMs = 0.0
    public private(set) var lastScanMs: Double?
    public private(set) var scannedLayers = 0
    /// Frames kept for the percentiles.
    public static let window = 240

    public init() {}

    mutating func addFrame(_ ms: Double) {
        frameMs.append(ms)
        if frameMs.count > Self.window { frameMs.removeFirst(frameMs.count - Self.window) }
    }

    /// Adds `ms` to the newest frame (the window's render of the frame the tick counted).
    mutating func addToLastFrame(_ ms: Double) {
        guard !frameMs.isEmpty else { return addFrame(ms) }
        frameMs[frameMs.count - 1] += ms
    }

    mutating func addNote(_ ms: Double) {
        notes += 1
        noteTotalMs += ms
        noteMaxMs = max(noteMaxMs, ms)
    }

    mutating func addScan(_ ms: Double, layers: Int) {
        lastScanMs = ms
        scannedLayers = layers
    }

    /// The `p` (0...1) percentile of the kept frame costs; 0 with none.
    public func framePercentile(_ p: Double) -> Double {
        let sorted = frameMs.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[Int((Double(sorted.count - 1) * min(max(p, 0), 1)).rounded())]
    }

    /// Mean milliseconds per recorded start.
    public var noteMeanMs: Double { notes > 0 ? noteTotalMs / Double(notes) : 0 }
}

private extension String {
    nonisolated var nilIfEmpty: String? { isEmpty ? nil : self }
}
