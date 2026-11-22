import AppKit
import CmuxNextDesign
import QuartzCore

/// A workspace row's agent task list (`SidebarTaskProgressLook`, Leo 2026-11-22 "DO IT PROPERLY"): the step in
/// progress on a row's second line with a muted "2 of 5" at its end, and a hairline at the row's foot while the chat
/// works. Neither takes room from the name's line.
extension WorkspaceRowView {
    func configureTaskPlan(_ shown: WorkspaceRowContent) {
        let count = shown.taskStep == nil ? nil : shown.tasks.map { Strings.taskStepOf($0.stepNumber, total: $0.total) }
        taskStepCount.setString(count ?? "")
        taskStepCount.isHidden = count == nil || isShowingPlaceholder
        taskBar = isShowingPlaceholder ? nil : shown.taskBar
    }

    /// The "2 of 5" at the second line's end; the step's text gives way to it and fades before it.
    func layoutTaskStepCount() {
        guard !taskStepCount.isHidden, !subtitle.isHidden else { taskStepCount.frame = .zero; return }
        let size = taskStepCount.naturalSize
        let w = ceil(size.width)
        taskStepCount.frame = NSRect(x: subtitle.frame.maxX - w, y: subtitle.frame.minY, width: w, height: subtitle.frame.height)
        subtitle.frame.size.width = max(0, subtitle.frame.width - w - Metrics.space1)
    }

    /// The hairline sits where a reported progress bar would (the row's foot, the text column's width); a reported
    /// bar keeps the foot (`SidebarLayoutOptions.applyTaskProgress` sets no `taskBar` beside one).
    func layoutTaskBar(x: CGFloat, width: CGFloat, bottom: CGFloat) {
        guard let taskBar, progress == nil, width > 0 else { taskBarLayer.isHidden = true; return }
        let height = SidebarTaskBarLayer.height
        taskBarLayer.isHidden = false
        taskBarLayer.frame = CGRect(x: x, y: bottom - height - 1, width: width, height: height)
        performWithTheme {
            taskBarLayer.update(taskBar, track: Palette.textTertiary.withAlphaComponent(0.25).cgColor,
                                fill: Palette.accent.cgColor, current: Palette.accent.withAlphaComponent(0.45).cgColor)
        }
    }
}

/// The task-list hairline (`SidebarTaskBar`): a track and the share done, or one segment per step (done, in progress,
/// left) for a short list. Shape layers, so a step changing redraws no row content.
final class SidebarTaskBarLayer: CALayer {
    static let height: CGFloat = 2
    /// The room between two steps' segments.
    static let gap: CGFloat = 2

    private let track = CAShapeLayer(), done = CAShapeLayer(), current = CAShapeLayer()
    private var drawn: (SidebarTaskBar, CGSize)?

    override init() {
        super.init()
        // Nothing here animates: a step finishing swaps a segment's fill at once, as the row's other marks change.
        let still: [String: any CAAction] = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull(), "path": NSNull(),
                                             "fillColor": NSNull(), "frame": NSNull()]
        actions = still
        for part in [track, done, current] { part.actions = still; addSublayer(part) }
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The rects each part fills, in the layer's bounds of `size`: the track, the steps done and the step in progress.
    static func parts(_ bar: SidebarTaskBar, size: CGSize) -> (track: [CGRect], done: [CGRect], current: [CGRect]) {
        let p = bar.progress, h = size.height
        guard bar.segmented else {
            let fill = CGRect(x: 0, y: 0, width: (size.width * p.fraction).rounded(), height: h)
            return ([CGRect(origin: .zero, size: size)], fill.width > 0 ? [fill] : [], [])
        }
        let n = CGFloat(p.total), segment = max(1, (size.width - gap * (n - 1)) / n)
        let rects = (0..<p.total).map { CGRect(x: CGFloat($0) * (segment + gap), y: 0, width: segment, height: h) }
        let inProgress = p.current != nil && p.done < p.total ? [rects[p.done]] : []
        return (Array(rects[(p.done + inProgress.count)...]), Array(rects[..<p.done]), inProgress)
    }

    func update(_ bar: SidebarTaskBar, track trackColor: CGColor, fill: CGColor, current currentColor: CGColor) {
        (track.fillColor, done.fillColor, current.fillColor) = (trackColor, fill, currentColor)
        guard drawn.map({ $0.0 != bar || $0.1 != bounds.size }) ?? true else { return }
        drawn = (bar, bounds.size)
        let parts = Self.parts(bar, size: bounds.size)
        func path(_ rects: [CGRect]) -> CGPath {
            let path = CGMutablePath()
            for rect in rects { path.addRoundedRect(in: rect, cornerWidth: min(rect.height, rect.width) / 2, cornerHeight: min(rect.height, rect.width) / 2) }
            return path
        }
        for layer in [track, done, current] { layer.frame = bounds }
        (track.path, done.path, current.path) = (path(parts.track), path(parts.done), path(parts.current))
    }
}
