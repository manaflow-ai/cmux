#if canImport(UIKit) && DEBUG
import CmuxConversationCore
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
///
/// To attribute every hitch, each row also carries what our own code did
/// since the previous row: the store changes received, the time spent in
/// each transcript section (with its start, so work outside an update is
/// placed too), whether a page landing restored its anchor and the offset it
/// wrote, each new cell's row kind and configure time, and the main run
/// loop's busy spans over 4 ms (a run loop observer: work between updates
/// shows there even when no update records it). The glass column counts
/// trait changes the header's and composer's views received (the system
/// glass re-evaluating the backdrop under them).
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
        observeRunLoop()
        observeGlass(in: [controller.header, controller.composerContainer])
        let screen = scrollView.window?.screen ?? UIScreen.main
        let environment = ProcessInfo.processInfo.environment
        let toggles = ["CMUX_UITEST_CONVERSATION_DYNAMICS", "CMUX_UITEST_CONVERSATION_SCROLL_RATE", "CMUX_UITEST_CONVERSATION_FILL", ConversationAutoScrollDriver.environmentKey]
            .compactMap { key in environment[key].map { "\(key)=\($0)" } }.joined(separator: " ")
        let header = "# label=\(label) maxFPS=\(screen.maximumFramesPerSecond) scale=\(screen.scale) os=\(UIDevice.current.systemVersion) \(toggles)\n"
            + "frame,model,present,deadline,t0,t1,t2,t3,t4,t5,offset,content,tracking,decel,dragging,vel,touchT,touchY,touchN,newCells,"
            + "changes,secs,restore,newKinds,insetTop,toTop,pan,panTouches,busy,glass,cells\n"
        let url = output
        writer.async {
            // A conversation shown again keeps appending to the same run.
            if FileManager.default.fileExists(atPath: url.path) {
                guard let handle = try? FileHandle(forWritingTo: url) else { return }
                // A probe line that cannot be appended is dropped (never written over the run's start).
                if (try? handle.seekToEnd()) != nil {
                    try? handle.write(contentsOf: Data(header.split(separator: "\n", maxSplits: 1).first.map { "\($0) (shown again)\n" }?.utf8 ?? "".utf8))
                }
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
        if let observer = runLoopObserver {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            runLoopObserver = nil
        }
        for (view, registration) in glassRegistrations { view?.unregisterForTraitChanges(registration) }
        glassRegistrations = []
        flush()
    }

    // MARK: Attribution

    /// Store changes the transcript received since the last row.
    private var changes: [String] = []
    /// `code@start+ms` for each section our code ran since the last row.
    private var sections: [String] = []
    /// What each page landing's anchor restore wrote (`y=<offset>`), or why
    /// it wrote nothing (`miss` no anchor, `lost` anchor row gone).
    private var restores: [String] = []
    /// `kind:ms` for each cell configured since the last row.
    private var configured: [String] = []
    /// `start+ms` for each main run loop busy span over 4 ms.
    private var busy: [String] = []
    private var glassChanges = 0
    private var runLoopObserver: CFRunLoopObserver?
    private var busySince: CFTimeInterval?
    private var glassRegistrations: [(view: UIView?, registration: any UITraitChangeRegistration)] = []

    func noteChange(_ change: ConversationStoreChange) {
        changes.append(Self.code(change))
    }

    func noteSection(_ section: ConversationProbeSection, start: CFTimeInterval) {
        let now = CACurrentMediaTime()
        sections.append(String(format: "%@@%.4f+%.2f", section.rawValue, start, (now - start) * 1000))
    }

    func noteRestore(_ outcome: String) {
        restores.append(outcome)
    }

    func noteCell(_ row: ConversationRow, start: CFTimeInterval) {
        let now = CACurrentMediaTime()
        configured.append(String(format: "%@:%.2f", Self.kind(row), (now - start) * 1000))
    }

    private static func code(_ change: ConversationStoreChange) -> String {
        switch change {
        case .reset: return "reset"
        case .prepended: return "prepended"
        case let .live(inserted, mine): return "live\(inserted.count)\(mine ? "m" : "")"
        case .typing: return "typing"
        case .older: return "older"
        case .connection: return "connection"
        case .readState: return "readState"
        case .listState: return "listState"
        case .draft: return "draft"
        case .background: return "background"
        }
    }

    /// A short name for what a row draws (the configure path it takes).
    private static func kind(_ row: ConversationRow) -> String {
        switch row {
        case let .message(model):
            let message = model.message
            var kind = message.poll != nil ? "poll"
                : message.audioAttachment != nil ? "audio"
                : !message.attachments.isEmpty ? "file"
                : message.linkPreview != nil ? "link"
                : message.isUnsent ? "unsent"
                : model.isEmojiOnly ? "emoji"
                : "text"
            if message.effect != nil { kind += "+fx" }
            // Animated text (shake, explode, ...) renders a glyph per letter.
            if message.textRuns.contains(where: { $0.effect != nil }) { kind += "+textfx" }
            if model.replyQuote != nil { kind += "+reply" }
            if !model.reactionKinds.isEmpty { kind += "+tapback" }
            if model.translation != nil { kind += "+translation" }
            return kind
        case .conversationStart: return "start"
        case .loadingOlder: return "loading"
        case .timestamp: return "timestamp"
        case .typing: return "typing"
        case .notice: return "notice"
        case .sendLaterHeader: return "sendLater"
        case .systemEvent: return "systemEvent"
        case .unavailability: return "unavailability"
        }
    }

    /// Busy spans of the main run loop (awake to about to sleep), in every
    /// common mode (scroll tracking included).
    private func observeRunLoop() {
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
            | CFRunLoopActivity.entry.rawValue | CFRunLoopActivity.exit.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, Int.max) { [weak self] _, activity in
            MainActor.assumeIsolated { self?.runLoop(activity) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        runLoopObserver = observer
    }

    private func runLoop(_ activity: CFRunLoopActivity) {
        let now = CACurrentMediaTime()
        switch activity {
        case .afterWaiting, .entry:
            if busySince == nil { busySince = now }
        case .beforeWaiting, .exit:
            guard let since = busySince else { return }
            busySince = nil
            if now - since > 0.004 { busy.append(String(format: "%.4f+%.2f", since, (now - since) * 1000)) }
        default:
            break
        }
    }

    /// Counts trait changes on the glass hosts' views. Registering changes
    /// nothing about how they draw.
    private func observeGlass(in roots: [UIView]) {
        guard #available(iOS 17.0, *) else { return }
        var views: [UIView] = []
        func collect(_ view: UIView) {
            views.append(view)
            view.subviews.forEach(collect)
        }
        roots.forEach(collect)
        for view in views {
            let registration = view.registerForTraitChanges(UITraitCollection.systemTraitsAffectingColorAppearance) { [weak self] (_: UIView, _: UITraitCollection) in
                self?.glassChanges += 1
            }
            glassRegistrations.append((view, registration))
        }
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
            "%ATTR%",
            String(format: "%.1f", scrollView.adjustedContentInset.top),
            controller.isScrollingToTop ? "1" : "0",
            "\(scrollView.panGestureRecognizer.state.rawValue)",
            "\(scrollView.panGestureRecognizer.numberOfTouches)",
            "%TAIL%",
            cells.joined(separator: "|"),
        ].joined(separator: ",")
    }

    private func finishRow() {
        defer { phases = [Double](repeating: .nan, count: 6) }
        guard let pending else { return }
        self.pending = nil
        frame += 1
        // What our code did up to this commit's end (its layout and new
        // cells included), placed before the update's scroll state columns.
        let attribution = [
            changes.joined(separator: ";"),
            sections.joined(separator: ";"),
            restores.joined(separator: ";"),
            configured.joined(separator: ";"),
        ].joined(separator: ",")
        let tail = [busy.joined(separator: ";"), "\(glassChanges)"].joined(separator: ",")
        changes.removeAll(keepingCapacity: true)
        sections.removeAll(keepingCapacity: true)
        restores.removeAll(keepingCapacity: true)
        configured.removeAll(keepingCapacity: true)
        busy.removeAll(keepingCapacity: true)
        glassChanges = 0
        rows.append("\(frame)," + pending
            .replacingOccurrences(of: "%T5%", with: String(format: "%.6f", phases[5]))
            .replacingOccurrences(of: "%ATTR%", with: attribution)
            .replacingOccurrences(of: "%TAIL%", with: tail))
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
                // A probe chunk that cannot be appended is dropped (never written over the run's start).
                if (try? handle.seekToEnd()) != nil { try? handle.write(contentsOf: data) }
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
