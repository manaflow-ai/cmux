#if canImport(UIKit) && DEBUG
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// DEBUG lab: `CMUX_UITEST_CONVERSATION_SCROLL_PROBE=<label>` writes one CSV
/// row per UI update the transcript takes part in to
/// `Documents/scroll-probe-<label>.csv` in the app's container, so scrolling
/// can be compared frame by frame across builds, simulators and the device.
///
/// It observes passively (a `UIUpdateLink` that never requests updates and a
/// touch observer that never recognizes), so it does not change the frame
/// rate it records. Each row has the update's timing (model, estimated
/// presentation and deadline times; event, display-link and commit phase
/// times), the scroll state, the latest finger sample, and every visible
/// message row's place on screen, from which the motion's pacing (frame
/// intervals), rigidity (rows moving by anything but the offset) and finger
/// tracking are computed offline.
@MainActor
final class ConversationScrollProbe {
    static let environmentKey = "CMUX_UITEST_CONVERSATION_SCROLL_PROBE"

    private weak var controller: ConversationViewController?
    private let label: String
    private var link: AnyObject?
    private let touches = TouchObserver()
    private var frame = 0
    /// Phase times of the update in progress (CACurrentMediaTime).
    private var phases = [Double](repeating: .nan, count: 6)
    private var rows: [String] = []
    private var visible: Set<ObjectIdentifier> = []
    /// Short stable numbers for row ids, in order of first sight.
    private var rowNumbers: [String: Int] = [:]
    private let output: URL
    private let writer = DispatchQueue(label: "com.cmux.conversation.scroll-probe", qos: .utility)

    init(controller: ConversationViewController, label: String) {
        self.controller = controller
        self.label = label
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        output = documents.appendingPathComponent("scroll-probe-\(label).csv")
    }

    /// The probe the environment asks for, or nil.
    static func fromEnvironment(controller: ConversationViewController) -> ConversationScrollProbe? {
        guard let label = ProcessInfo.processInfo.environment[environmentKey], !label.isEmpty else { return nil }
        return ConversationScrollProbe(controller: controller, label: label)
    }

    func start() {
        guard link == nil, let controller, #available(iOS 18.0, *) else { return }
        let scrollView = controller.collectionView
        touches.cancelsTouchesInView = false
        touches.delaysTouchesBegan = false
        touches.delaysTouchesEnded = false
        scrollView.addGestureRecognizer(touches)
        // Passive by default: its actions run only in updates something
        // else produces (`requiresContinuousUpdates` stays false).
        let link = UIUpdateLink(view: scrollView)
        let marks: [(UIUpdateActionPhase, Int)] = [
            (.beforeEventDispatch, 0), (.afterEventDispatch, 1),
            (.beforeCADisplayLinkDispatch, 2), (.afterCADisplayLinkDispatch, 3),
        ]
        for (phase, slot) in marks {
            link.addAction(to: phase) { [weak self] _, _ in self?.phases[slot] = CACurrentMediaTime() }
        }
        link.addAction(to: .beforeCATransactionCommit) { [weak self] _, info in
            self?.phases[4] = CACurrentMediaTime()
            self?.capture(info)
        }
        link.addAction(to: .afterCATransactionCommit) { [weak self] _, _ in
            self?.phases[5] = CACurrentMediaTime()
            self?.finishRow()
        }
        link.isEnabled = true
        self.link = link
        let screen = scrollView.window?.screen ?? UIScreen.main
        let environment = ProcessInfo.processInfo.environment
        let toggles = ["CMUX_UITEST_CONVERSATION_DYNAMICS", "CMUX_UITEST_CONVERSATION_SCROLL_RATE", "CMUX_UITEST_CONVERSATION_FILL", ConversationAutoScrollDriver.environmentKey]
            .compactMap { key in environment[key].map { "\(key)=\($0)" } }.joined(separator: " ")
        let header = "# label=\(label) maxFPS=\(screen.maximumFramesPerSecond) scale=\(screen.scale) os=\(UIDevice.current.systemVersion) \(toggles)\n"
            + "frame,model,present,deadline,t0,t1,t2,t3,t4,t5,offset,content,tracking,decel,dragging,vel,touchT,touchY,touchN,newCells,cells\n"
        let url = output
        writer.async {
            // A conversation shown again keeps appending to the same run.
            if FileManager.default.fileExists(atPath: url.path) {
                guard let handle = try? FileHandle(forWritingTo: url) else { return }
                handle.seekToEndOfFile()
                handle.write(Data(header.split(separator: "\n", maxSplits: 1).first.map { "\($0) (shown again)\n" }?.utf8 ?? "".utf8))
                try? handle.close()
            } else {
                try? header.data(using: .utf8)?.write(to: url)
            }
        }
    }

    func stop() {
        if #available(iOS 18.0, *), let link = link as? UIUpdateLink { link.isEnabled = false }
        link = nil
        touches.view?.removeGestureRecognizer(touches)
        flush()
    }

    /// Row state as it is committed in this update.
    private var pending: String?
    /// The transcript was neither dragged nor decelerating in that update.
    private var settled = false
    private var wasMoving = false

    @available(iOS 18.0, *)
    private func capture(_ info: UIUpdateInfo) {
        guard let controller else { return }
        let scrollView = controller.collectionView
        let offset = scrollView.contentOffset.y
        let velocity = scrollView.isTracking ? scrollView.panGestureRecognizer.velocity(in: scrollView).y : 0
        var cells: [String] = []
        var now: Set<ObjectIdentifier> = []
        var fresh = 0
        for case let cell as MessageCell in scrollView.visibleCells {
            guard let rowID = cell.model?.rowID else { continue }
            let id = ObjectIdentifier(cell)
            now.insert(id)
            if !visible.contains(id) { fresh += 1 }
            let number = rowNumbers[rowID] ?? {
                let next = rowNumbers.count
                rowNumbers[rowID] = next
                return next
            }()
            // Where the row's content is drawn, relative to the transcript's
            // top edge: its frame, the scroll, and any offset applied on top
            // of the layout (a glide's transform, a dynamics lag).
            let y = cell.frame.minY - offset + cell.layer.sublayerTransform.m42 + cell.contentView.transform.ty
            let animating = (cell.layer.animationKeys()?.isEmpty == false)
                || (cell.contentView.layer.animationKeys()?.isEmpty == false)
            cells.append("\(number):\(String(format: "%.3f", y)):\(animating ? 1 : 0)")
        }
        visible = now
        let touch = touches.latest
        settled = !scrollView.isTracking && !scrollView.isDecelerating
        pending = [
            String(format: "%.6f", info.modelTime),
            String(format: "%.6f", info.estimatedPresentationTime),
            String(format: "%.6f", info.completionDeadlineTime),
            String(format: "%.6f", phases[0]), String(format: "%.6f", phases[1]),
            String(format: "%.6f", phases[2]), String(format: "%.6f", phases[3]),
            String(format: "%.6f", phases[4]),
        ].joined(separator: ",") + ",%T5%," + [
            String(format: "%.3f", offset),
            String(format: "%.1f", scrollView.contentSize.height),
            scrollView.isTracking ? "1" : "0",
            scrollView.isDecelerating ? "1" : "0",
            scrollView.isDragging ? "1" : "0",
            String(format: "%.1f", velocity),
            String(format: "%.6f", touch.time),
            String(format: "%.3f", touch.y),
            "\(touches.take())",
            "\(fresh)",
            cells.joined(separator: "|"),
        ].joined(separator: ",")
    }

    private func finishRow() {
        defer { phases = [Double](repeating: .nan, count: 6) }
        guard let pending else { return }
        self.pending = nil
        frame += 1
        rows.append("\(frame)," + pending.replacingOccurrences(of: "%T5%", with: String(format: "%.6f", phases[5])))
        // Written every 2 s of updates and whenever the scroll comes to
        // rest, so a run copied off the device right after ends complete.
        if rows.count >= 240 || (settled && wasMoving) { flush() }
        wasMoving = !settled
    }

    /// Appends the buffered rows off the main thread.
    private func flush() {
        guard !rows.isEmpty else { return }
        let chunk = rows.joined(separator: "\n") + "\n"
        rows.removeAll(keepingCapacity: true)
        let url = output
        writer.async {
            guard let data = chunk.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Sees every transcript touch and never recognizes, so it changes
    /// nothing about how the scroll view or the other recognizers behave.
    private final class TouchObserver: UIGestureRecognizer {
        private(set) var latest: (time: Double, y: CGFloat) = (.nan, .nan)
        private var count = 0

        func take() -> Int {
            defer { count = 0 }
            return count
        }

        private func note(_ touches: Set<UITouch>, _ event: UIEvent) {
            guard let touch = touches.first, let window = view?.window else { return }
            let samples = event.coalescedTouches(for: touch) ?? [touch]
            count += samples.count
            latest = (touch.timestamp, touch.location(in: window).y)
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { note(touches, event) }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { note(touches, event) }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            note(touches, event)
            state = .failed
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }
        // Never prevents, and is never prevented by, another recognizer, so
        // it keeps seeing the touch after the scroll pan takes it.
        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    }
}
#endif
