import AppKit
import CmuxNextDesign
import CmuxNextWakeups
import QuartzCore

/// Sleepy Mode's scene: a night sky with twinkling stars, a moon, drifting Zs,
/// the clock and how many of this Mac's agents run a turn. A click anywhere
/// but the Lock Mac button wakes it.
///
/// AppKit and Core Animation (plans/cmux-next/no-swiftui-DESIGN.md): the stars
/// and Zs are layers whose loops run in the render server, so a scene left up
/// for hours costs no main-thread frames; only the clock and the agent count
/// update, once a second. Loops run only while `Motion.panes.animatesLoops`
/// (the master switch, Panes and Windows, speed off or Reduce Motion stop them:
/// a still sky).
final class SleepySceneView: NSView {
    private let workingAgents: @MainActor () -> Int
    private let wake: @MainActor () -> Void
    private let lockMac: @MainActor () -> Void
    private let sky = CALayer()
    private var stars: [CALayer] = []
    private var zs: [CATextLayer] = []
    private let clock = NSTextField(labelWithString: "")
    private let agents = NSTextField(labelWithString: "")
    private let ticker = DemandTimer(owner: "SleepySceneView.tick")
    private let clockFormat = Date.FormatStyle.dateTime.hour().minute()

    // The scene's art sizes (a full-screen clock and moon), above the UI type scale on purpose.
    private static let moonSize: CGFloat = 96
    private static let clockSize: CGFloat = 64
    private static let zSize: CGFloat = 18

    private static let background = NSColor(srgbRed: 0.03, green: 0.04, blue: 0.12, alpha: 1)
    private static let moon = NSColor(srgbRed: 1.0, green: 0.92, blue: 0.62, alpha: 1)

    /// - Parameters:
    ///   - workingAgents: The count of this Mac's agents running a turn, read once a second.
    ///   - wake: A click anywhere but the Lock Mac button.
    ///   - lockMac: The Lock Mac button.
    init(workingAgents: @escaping @MainActor () -> Int, wake: @escaping @MainActor () -> Void,
         lockMac: @escaping @MainActor () -> Void) {
        self.workingAgents = workingAgents
        self.wake = wake
        self.lockMac = lockMac
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Self.background.cgColor
        layer?.addSublayer(sky)
        makeStars()
        makeZs()
        buildCenter()
        tick()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) { wake() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        ticker.cancel()
        guard window != nil else { return }
        scheduleTick()
        startLoops()
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated { ticker.cancel() }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sky.frame = bounds
        placeStars()
        placeZs()
        CATransaction.commit()
    }

    // MARK: Center column

    private func buildCenter() {
        let moonView = NSImageView(image: NSImage(systemSymbolName: "moon.zzz.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: Self.moonSize, weight: .regular)) ?? NSImage())
        moonView.contentTintColor = Self.moon

        clock.font = Self.rounded(Self.clockSize, weight: .thin, monospacedDigits: true)
        clock.textColor = .white
        clock.setAccessibilityIdentifier("cmux.sleepy.clock")
        agents.font = .preferredFont(forTextStyle: .title3)
        agents.textColor = .white.withAlphaComponent(0.7)
        agents.setAccessibilityIdentifier("cmux.sleepy.agents")
        let readout = NSStackView(views: [clock, agents])
        readout.orientation = .vertical
        readout.spacing = 8

        let lock = NSButton(title: SleepyModeStrings.lockMac, image: NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil) ?? NSImage(),
                            target: self, action: #selector(lockClicked))
        lock.imagePosition = .imageLeading
        lock.bezelStyle = .rounded
        lock.controlSize = .large
        lock.bezelColor = .white.withAlphaComponent(0.25)
        lock.contentTintColor = .white
        lock.appearance = NSAppearance(named: .darkAqua)
        lock.setAccessibilityIdentifier("cmux.sleepy.lockMac")
        let lockBox = NSStackView(views: [lock])
        lockBox.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 0, right: 0)

        let hint = NSTextField(labelWithString: SleepyModeStrings.hint)
        hint.font = .preferredFont(forTextStyle: .callout)
        hint.textColor = .white.withAlphaComponent(0.5)

        let column = NSStackView(views: [moonView, readout, lockBox, hint])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 18
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func tick() {
        clock.stringValue = Date.now.formatted(clockFormat)
        clock.setAccessibilityLabel(clock.stringValue)
        let working = workingAgents()
        agents.stringValue = working == 0 ? SleepyModeStrings.noAgentsWorking : SleepyModeStrings.agentsWorking(working)
        agents.setAccessibilityLabel(agents.stringValue)
    }

    /// The next clock and agent-count update, one second out; each update schedules the next
    /// while the scene is in a window (a one-shot deadline per second, the scene's update rate).
    private func scheduleTick() {
        ticker.schedule(after: .seconds(1)) { @MainActor [weak self] in
            guard let self, self.window != nil else { return }
            self.tick()
            self.scheduleTick()
        }
    }

    @objc private func lockClicked() { lockMac() }

    /// The system font in its rounded design at `size`.
    private static func rounded(_ size: CGFloat, weight: NSFont.Weight, monospacedDigits: Bool) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        var descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        if monospacedDigits {
            descriptor = descriptor.addingAttributes([.featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
            ]]])
        }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    // MARK: Sky

    /// Star spots as fractions of the scene (a seeded walk: the same sky every time), with
    /// each star's twinkle phase and radius.
    private static let starSpots: [(x: Double, y: Double, phase: Double, radius: Double)] = {
        var seed: UInt64 = 0x5EED
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        return (0..<90).map { _ in (next(), next(), next(), 0.6 + next() * 1.4) }
    }()

    private func makeStars() {
        stars = Self.starSpots.map { spot in
            let star = CALayer()
            star.backgroundColor = NSColor.white.cgColor
            star.bounds = CGRect(x: 0, y: 0, width: spot.radius * 2, height: spot.radius * 2)
            star.cornerRadius = spot.radius
            // The still sky's brightness (the twinkle's midpoint).
            star.opacity = Float(0.35 + 0.65 * (0.5 + 0.5 * sin(spot.phase * .pi * 2)))
            sky.addSublayer(star)
            return star
        }
    }

    private func placeStars() {
        for (star, spot) in zip(stars, Self.starSpots) {
            star.position = CGPoint(x: spot.x * bounds.width, y: spot.y * bounds.height)
        }
    }

    private func makeZs() {
        zs = (0..<3).map { _ in
            let z = CATextLayer()
            z.string = "z"
            z.font = Self.rounded(Self.zSize, weight: .semibold, monospacedDigits: false)
            z.fontSize = Self.zSize
            z.foregroundColor = NSColor.white.cgColor
            z.alignmentMode = .center
            z.bounds = CGRect(x: 0, y: 0, width: 40, height: 40)
            z.contentsScale = window?.backingScaleFactor ?? 2
            z.opacity = 0
            sky.addSublayer(z)
            return z
        }
    }

    /// The Zs' origin: beside the moon's corner, above the center.
    private var zOrigin: CGPoint { CGPoint(x: bounds.midX + 60, y: bounds.midY - 150) }

    private func placeZs() {
        for z in zs {
            z.position = zOrigin
            z.contentsScale = window?.backingScaleFactor ?? 2
        }
        startLoops()
    }

    /// Starts (or restarts, after a resize) the render-server loops; a still sky when loops are off.
    private func startLoops() {
        for star in stars { star.removeAllAnimations() }
        for z in zs { z.removeAllAnimations() }
        guard window != nil, bounds.width > 0, Motion.panes.animatesLoops,
              let twinkle = Motion.panes.pulseAnimation(low: 0.35) else { return }
        let period = twinkle.duration
        for (star, spot) in zip(stars, Self.starSpots) {
            guard let copy = twinkle.copy() as? CAAnimation else { continue }
            copy.timeOffset = spot.phase * period
            star.add(copy, forKey: "sleepy.twinkle")
        }
        let rise = period * 2
        for (index, z) in zs.enumerated() {
            // The rise is timed from the gate's own pulse period, so speed and Reduce Motion follow the switches.
            // motion: allow the Zs' rise runs only while Motion.panes.animatesLoops (guarded above)
            let group = CAAnimationGroup()
            group.animations = [zPath(), zFade(), zGrow()]
            group.duration = rise
            group.repeatCount = .infinity
            group.timeOffset = rise * Double(index) / 3
            group.isRemovedOnCompletion = false
            z.add(group, forKey: "sleepy.rise")
        }
    }

    private func zPath() -> CAAnimation {
        let origin = zOrigin
        let points = stride(from: 0.0, through: 1.0, by: 0.1).map { progress in
            NSValue(point: CGPoint(x: origin.x + progress * 50 + sin(progress * .pi * 2) * 8, y: origin.y - progress * 90))
        }
        // motion: allow part of the Zs' rise group, which runs only while Motion.panes.animatesLoops
        let path = CAKeyframeAnimation(keyPath: "position")
        path.values = points
        return path
    }

    private func zFade() -> CAAnimation {
        // motion: allow part of the Zs' rise group, which runs only while Motion.panes.animatesLoops
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        return fade
    }

    private func zGrow() -> CAAnimation {
        // motion: allow part of the Zs' rise group, which runs only while Motion.panes.animatesLoops
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = 2
        return grow
    }
}
