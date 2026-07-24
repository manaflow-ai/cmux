import AppKit
import Combine
import Darwin
import Foundation

// MARK: - Untrusted cursor feed model

/// A validated snapshot of the computer-use driver's cursor feed file
/// (`<driver_pid>.cursor.json`). Parsed defensively because the file is
/// untrusted input written by a separate process.
struct ComputerUseCursorState: Equatable, Sendable {
    let driverPID: Int
    let session: String?
    let visible: Bool
    /// Global, top-left-origin desktop coordinate (y increases downward).
    let x: Double
    let y: Double
    let label: String?
    /// Normalized `#rrggbb` / `#rrggbbaa` hex strings; empty when unspecified.
    let gradient: [String]
    /// Normalized hex string, or `nil` when unspecified.
    let bloom: String?
    let updatedAt: Date

    init?(data: Data) {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any],
            let driverPID = Self.positiveInt(dictionary["driver_pid"] ?? dictionary["pid"]),
            let x = Self.finiteDouble(dictionary["x"]),
            let y = Self.finiteDouble(dictionary["y"]),
            let updatedAt = Self.date(dictionary["updated_at"] ?? dictionary["last_action_at"])
        else {
            return nil
        }

        self.driverPID = driverPID
        self.session = Self.boundedNonemptyString(dictionary["session"], maximumUTF8Bytes: 1_024)
        self.visible = Self.bool(dictionary["visible"]) ?? false
        self.x = x
        self.y = y
        self.label = Self.boundedNonemptyString(dictionary["label"], maximumUTF8Bytes: 256)
        self.gradient = Self.hexArray(dictionary["gradient"])
        self.bloom = Self.hex(dictionary["bloom"])
        self.updatedAt = updatedAt
    }

    private static func positiveInt(_ value: Any?) -> Int? {
        if let number = value as? NSNumber, String(cString: number.objCType) != "c" {
            let doubleValue = number.doubleValue
            guard doubleValue.isFinite, doubleValue.rounded() == doubleValue else { return nil }
            guard let parsed = Int(exactly: doubleValue), parsed > 0, parsed <= Int(Int32.max) else { return nil }
            return parsed
        }
        if let string = value as? String, let parsed = Int(string), parsed > 0, parsed <= Int(Int32.max) {
            return parsed
        }
        return nil
    }

    private static func finiteDouble(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, String(cString: number.objCType) != "c" {
            let doubleValue = number.doubleValue
            return doubleValue.isFinite ? doubleValue : nil
        }
        if let string = value as? String, let parsed = Double(string), parsed.isFinite {
            return parsed
        }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber, String(cString: number.objCType) == "c" {
            return number.boolValue
        }
        if let boolValue = value as? Bool {
            return boolValue
        }
        if let string = value as? String {
            switch string.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }

    private static func boundedNonemptyString(_ value: Any?, maximumUTF8Bytes: Int) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumUTF8Bytes else { return nil }
        return trimmed
    }

    private static func hexArray(_ value: Any?) -> [String] {
        guard let array = value as? [Any] else { return [] }
        // Cap the number of stops to keep an untrusted file from bloating the gradient.
        return array.prefix(8).compactMap { hex($0) }
    }

    private static func hex(_ value: Any?) -> String? {
        ComputerUseCursorColorParsing.normalizedHex(value as? String)
    }

    private static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber, String(cString: number.objCType) != "c" {
            return date(timeInterval: number.doubleValue)
        }
        guard let string = value as? String else { return nil }
        if let numeric = Double(string) {
            return date(timeInterval: numeric)
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: string) {
            return parsed
        }
        if let parsed = ISO8601DateFormatter().date(from: string) {
            return parsed
        }
        // The driver writes 6-digit fractional seconds, which ISO8601DateFormatter's
        // fractional mode rejects on some macOS versions; retry with milliseconds.
        if let match = string.range(of: #"\.(\d{3})\d+"#, options: .regularExpression) {
            var truncated = string
            let keep = string[match.lowerBound...].prefix(4)
            truncated.replaceSubrange(match, with: keep)
            return fractional.date(from: truncated)
        }
        return nil
    }

    private static func date(timeInterval: TimeInterval) -> Date? {
        guard timeInterval.isFinite, timeInterval > 0 else { return nil }
        let seconds = timeInterval > 10_000_000_000 ? timeInterval / 1_000 : timeInterval
        return Date(timeIntervalSince1970: seconds)
    }
}

// MARK: - Feed scanning (pure, injectable)

/// Selects the cursor the overlay should render from the untrusted feed directory.
struct ComputerUseCursorFeed: Sendable {
    // Keep the cursor on-screen across the gaps *between* actions (a click is
    // followed by a slow get_window_state screenshot, often several seconds), so
    // consecutive actions glide the same visible cursor from one target to the
    // next instead of fading it out and re-appearing at each spot. The driver
    // writes visible=false at end_session, which hides it immediately regardless.
    static let defaultFreshnessInterval: TimeInterval = 20
    private static let maximumFutureClockSkew: TimeInterval = 5 * 60
    private static let maximumFileBytes = 64 * 1_024
    private static let fileSuffix = ".cursor.json"

    /// A cursor feed is considered live only while its `updated_at` is within this
    /// window; the driver keeps rewriting the file while it drives the pointer.
    let freshnessInterval: TimeInterval

    init(freshnessInterval: TimeInterval = Self.defaultFreshnessInterval) {
        self.freshnessInterval = freshnessInterval
    }

    /// Returns the most-recently-updated visible + fresh cursor, or `nil` when
    /// nothing should be shown.
    func scan(
        directoryURL: URL,
        now: Date,
        fileManager: FileManager = .default
    ) -> ComputerUseCursorState? {
        guard
            let urls = try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return nil
        }

        var best: ComputerUseCursorState?
        for url in urls where url.lastPathComponent.hasSuffix(Self.fileSuffix) {
            guard
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                values.isRegularFile == true,
                values.isSymbolicLink != true,
                let fileSize = values.fileSize,
                fileSize > 0,
                fileSize <= Self.maximumFileBytes,
                let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                let state = ComputerUseCursorState(data: data),
                state.visible,
                isFresh(state.updatedAt, now: now)
            else {
                continue
            }
            if let current = best, current.updatedAt >= state.updatedAt {
                continue
            }
            best = state
        }
        return best
    }

    func isFresh(_ date: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(date)
        return age >= -Self.maximumFutureClockSkew && age <= freshnessInterval
    }
}

// MARK: - Coordinate conversion (pure)

/// Converts feed coordinates (global, top-left origin) into AppKit global
/// coordinates (bottom-left origin) and the overlay window origin.
enum ComputerUseCursorOverlayGeometry {
    /// Exact window size used by Lawrence's browser-agent pointer view.
    static let windowSize = CGSize(width: 24, height: 30)
    /// Distance from the window's top-left corner to the pointer tip.
    static let hotspotInset: CGFloat = 0.5

    /// Flip a global top-left-origin feed point to a global AppKit bottom-left
    /// point. `primaryScreenMaxY` is `NSScreen.screens[0].frame.maxY` (the primary
    /// display height for a standard origin), which anchors both coordinate
    /// systems; the same flip is valid for points on secondary displays because
    /// AppKit's global space shares the primary display's bottom-left origin.
    static func appKitPoint(feedX: Double, feedY: Double, primaryScreenMaxY: CGFloat) -> CGPoint {
        CGPoint(x: CGFloat(feedX), y: primaryScreenMaxY - CGFloat(feedY))
    }

    /// The bottom-left window origin that places the hotspot at `hotspot`.
    static func windowOrigin(forAppKitHotspot hotspot: CGPoint) -> CGPoint {
        CGPoint(
            x: hotspot.x - hotspotInset,
            y: hotspot.y - (windowSize.height - hotspotInset)
        )
    }
}

// MARK: - Color parsing

enum ComputerUseCursorColorParsing {
    /// Validates and normalizes a `#rrggbb` / `#rrggbbaa` hex string (with or
    /// without the leading `#`). Returns `nil` for anything else.
    static func normalizedHex(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6 || value.count == 8 else { return nil }
        guard value.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + value.uppercased()
    }
}

// MARK: - Overlay controller

/// Renders a floating, click-through, all-Spaces branded cursor that mirrors the
/// computer-use driver's cursor feed. Watches the untrusted feed directory and
/// glides the overlay to each new position, hiding when idle/stale/disabled.
@MainActor
final class ComputerUseCursorOverlayController {
    private let stateDirectoryURL: URL
    private let featureEnabled: @MainActor () -> Bool
    private let feed: ComputerUseCursorFeed
    private let pollInterval: TimeInterval
    private let glideDuration: TimeInterval

    private var panel: NSPanel?
    private var pointerView: AgentCursorPointerView?
    private var directoryWatchSource: DispatchSourceFileSystemObject?
    private let directoryWatchQueue = DispatchQueue(label: "com.cmuxterm.app.computerUseCursorWatch")
    /// The untrusted feed directory is scanned here, never on the main thread.
    private let scanQueue = DispatchQueue(label: "com.cmuxterm.app.computerUseCursorScan", qos: .utility)
    /// At most one background scan is outstanding; further ticks are dropped until
    /// it lands, which collapses a burst of watcher/timer events into one scan.
    private var scanInFlight = false
    private var pollTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var refreshCoalesceScheduled = false
    private var refreshCoalesceTask: Task<Void, Never>?
    private var scanGeneration = 0
    private var started = false

    init(
        stateDirectoryURL: URL,
        featureEnabled: @escaping @MainActor () -> Bool,
        feed: ComputerUseCursorFeed = ComputerUseCursorFeed(),
        pollInterval: TimeInterval = 0.75,
        glideDuration: TimeInterval = 0.35
    ) {
        self.stateDirectoryURL = stateDirectoryURL
        self.featureEnabled = featureEnabled
        self.feed = feed
        self.pollInterval = pollInterval
        self.glideDuration = glideDuration
    }

    deinit {
        refreshCoalesceTask?.cancel()
        directoryWatchSource?.cancel()
    }

    func start() {
        guard !started else { return }
        started = true
        scanGeneration &+= 1

        NotificationCenter.default.publisher(for: .cmuxFeatureFlagsDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            .store(in: &cancellables)

        startWatchingStateDirectory()
        // The filesystem watcher fires on writes, but the driver stops writing when
        // idle; a light poll detects staleness and hides the overlay on time.
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        refresh()
    }

    func stop() {
        started = false
        scanGeneration &+= 1
        scanInFlight = false
        refreshCoalesceTask?.cancel()
        refreshCoalesceTask = nil
        refreshCoalesceScheduled = false
        cancellables.removeAll()
        directoryWatchSource?.cancel()
        directoryWatchSource = nil
        pollTimer?.invalidate()
        pollTimer = nil
        hide(animated: false)
    }

    func refresh() {
        guard started, featureEnabled() else {
            hide(animated: false)
            return
        }
        // Never scan the untrusted feed directory on the main thread. The driver
        // rewrites its state files many times per second while driving, so doing
        // the directory enumeration + JSON reads inline here floods the main
        // thread with synchronous filesystem I/O and beachballs the app during
        // active computer use. Run the I/O on a utility queue and apply only the
        // small `Sendable` snapshot back on the main actor; `scanInFlight`
        // collapses a burst of poll ticks and filesystem events into one scan.
        guard !scanInFlight else { return }
        scanInFlight = true
        let generation = scanGeneration
        let feed = self.feed
        let directoryURL = self.stateDirectoryURL
        scanQueue.async(execute: Self.makeScanOperation(
            feed: feed,
            directoryURL: directoryURL,
            generation: generation,
            controller: self
        ))
    }

    /// The utility queue is outside `MainActor`; construct its callback in a
    /// nonisolated context and hop explicitly only after the filesystem scan.
    nonisolated private static func makeScanOperation(
        feed: ComputerUseCursorFeed,
        directoryURL: URL,
        generation: Int,
        controller: ComputerUseCursorOverlayController
    ) -> @Sendable () -> Void {
        { [weak controller] in
            let state = feed.scan(directoryURL: directoryURL, now: Date())
            Task { @MainActor [weak controller] in
                guard let controller else { return }
                guard generation == controller.scanGeneration else { return }
                controller.scanInFlight = false
                controller.applyScannedState(state)
            }
        }
    }

    private func applyScannedState(_ state: ComputerUseCursorState?) {
        guard started, featureEnabled() else {
            hide(animated: false)
            return
        }
        guard let state else {
            hide(animated: true)
            return
        }
        present(state)
    }

    private func present(_ state: ComputerUseCursorState) {
        guard let primaryMaxY = NSScreen.screens.first?.frame.maxY else { return }
        let panel = ensurePanel()

        let appKitPoint = ComputerUseCursorOverlayGeometry.appKitPoint(
            feedX: state.x,
            feedY: state.y,
            primaryScreenMaxY: primaryMaxY
        )
        let origin = ComputerUseCursorOverlayGeometry.windowOrigin(forAppKitHotspot: appKitPoint)
        move(panel, to: origin)
    }

    private func move(_ panel: NSPanel, to origin: CGPoint) {
        let wasVisible = panel.isVisible && panel.alphaValue > 0.01
        if !wasVisible {
            panel.setFrameOrigin(origin)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            pointerView?.needsDisplay = true
            pointerView?.displayIfNeeded()
            fade(panel, to: 1, animated: !reduceMotion)
            return
        }

        // Re-assert front on every move: when cmux brings the driven app to the
        // foreground (watchable mode) the activation can reshuffle window order,
        // and a one-time orderFront at first appearance would let the cursor get
        // buried behind the app it is supposed to be pointing at.
        panel.orderFrontRegardless()

        if reduceMotion {
            panel.setFrameOrigin(origin)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = glideDuration
                // Ease in *and* out so the cursor accelerates off its last target
                // and settles smoothly onto the next — a gliding path rather than a
                // snap, matching the feel of other computer-use cursors.
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                panel.animator().setFrameOrigin(origin)
            }
        }
    }

    private func hide(animated: Bool) {
        guard let panel, panel.isVisible else { return }
        fade(panel, to: 0, animated: animated && !reduceMotion) { [weak panel] in
            panel?.orderOut(nil)
        }
    }

    private func fade(_ panel: NSPanel, to alpha: CGFloat, animated: Bool, completion: (() -> Void)? = nil) {
        guard animated else {
            panel.alphaValue = alpha
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = alpha
        }, completionHandler: completion)
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func startWatchingStateDirectory() {
        guard directoryWatchSource == nil else { return }
        try? FileManager.default.createDirectory(
            at: stateDirectoryURL,
            withIntermediateDirectories: true
        )
        let descriptor = open(stateDirectoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .link, .rename, .delete],
            queue: directoryWatchQueue
        )
        source.setEventHandler(handler: Self.makeDirectoryWatchEventHandler(
            source: source,
            controller: self
        ))
        source.setCancelHandler(handler: Self.makeDirectoryWatchCancelHandler(
            descriptor: descriptor
        ))
        source.resume()
        directoryWatchSource = source
    }

    /// DispatchSource delivers on its own queue. Build the callback outside the
    /// main actor so Swift 6 does not trap before the explicit actor hop.
    nonisolated private static func makeDirectoryWatchEventHandler(
        source: DispatchSourceFileSystemObject,
        controller: ComputerUseCursorOverlayController
    ) -> @Sendable () -> Void {
        { [weak source, weak controller] in
            guard let source else { return }
            let events = source.data
            Task { @MainActor [weak controller] in
                controller?.handleDirectoryWatchEvent(
                    events,
                    from: source
                )
            }
        }
    }

    nonisolated private static func makeDirectoryWatchCancelHandler(
        descriptor: Int32
    ) -> @Sendable () -> Void {
        { Darwin.close(descriptor) }
    }

    private func handleDirectoryWatchEvent(
        _ events: DispatchSource.FileSystemEvent,
        from source: DispatchSourceFileSystemObject
    ) {
        guard directoryWatchSource === source else { return }
        if events.contains(.delete) || events.contains(.rename) {
            source.cancel()
            directoryWatchSource = nil
            startWatchingStateDirectory()
        }
        scheduleCoalescedRefresh()
    }

    /// Coalesce a burst of filesystem events into at most one refresh per frame.
    /// The driver rewrites the cursor feed many times per second while driving;
    /// refreshing on every raw event would flood the main thread with directory
    /// scans and beachball the app during active computer use.
    private func scheduleCoalescedRefresh() {
        guard started, !refreshCoalesceScheduled else { return }
        refreshCoalesceScheduled = true
        refreshCoalesceTask = Task { @MainActor [weak self] in
            do {
                // Genuine bounded debounce for one burst of directory events.
                try await ContinuousClock().sleep(for: .milliseconds(16))
            } catch {
                return
            }
            guard let self, self.started, !Task.isCancelled else { return }
            self.refreshCoalesceScheduled = false
            self.refreshCoalesceTask = nil
            self.refresh()
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: ComputerUseCursorOverlayGeometry.windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.alphaValue = 0
        // Keep the animated decorative window out of the accessibility hierarchy.
        // Its frame and ordering change throughout every cursor glide.
        panel.setAccessibilityElement(false)

        let pointer = AgentCursorPointerView(
            frame: CGRect(origin: .zero, size: ComputerUseCursorOverlayGeometry.windowSize)
        )
        pointer.autoresizingMask = [.width, .height]
        panel.contentView = pointer

        self.panel = panel
        self.pointerView = pointer
        return panel
    }
}
