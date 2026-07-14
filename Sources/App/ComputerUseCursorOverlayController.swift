import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI

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
    static let defaultFreshnessInterval: TimeInterval = 5
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
    /// Overlay window size. Roomy enough for the arrow, its bloom, and the pill.
    static let windowSize = CGSize(width: 176, height: 66)
    /// Distance from the window's top-left corner to the cursor hotspot (the tip
    /// of the arrow tip). Kept in sync with `ComputerUseCursorGlyph.hotspotInset`.
    static let hotspotInset: CGFloat = 22

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

// MARK: - Color parsing / presentation

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

/// Immutable render inputs for the branded cursor glyph. Resolving defaults here
/// keeps the SwiftUI view a pure function of value data.
struct ComputerUseCursorPresentation: Equatable {
    var gradientHexes: [String]
    var bloomHex: String
    var label: String

    static let defaultGradientHexes = ["#12C7F5", "#2D8CFF", "#6C5CFF"]
    static let defaultBloomHex = "#2D8CFF"
    static let defaultLabel = "cmux"

    static func make(from state: ComputerUseCursorState) -> ComputerUseCursorPresentation {
        ComputerUseCursorPresentation(
            gradientHexes: resolvedGradientHexes(state.gradient),
            bloomHex: state.bloom ?? defaultBloomHex,
            label: state.label ?? defaultLabel
        )
    }

    /// Falls back to the branded cmux gradient when the feed omits stops.
    static func resolvedGradientHexes(_ input: [String]) -> [String] {
        let normalized = input.compactMap(ComputerUseCursorColorParsing.normalizedHex)
        return normalized.isEmpty ? defaultGradientHexes : normalized
    }

    var gradientColors: [Color] {
        gradientHexes.compactMap(Color.init(cmuxCursorHex:))
    }

    var bloomColor: Color {
        Color(cmuxCursorHex: bloomHex) ?? Color(cmuxCursorHex: Self.defaultBloomHex) ?? .blue
    }
}

extension Color {
    init?(cmuxCursorHex hex: String) {
        guard let normalized = ComputerUseCursorColorParsing.normalizedHex(hex) else { return nil }
        let digits = normalized.dropFirst()
        guard let value = UInt64(digits, radix: 16) else { return nil }
        let r, g, b, a: Double
        if digits.count == 8 {
            r = Double((value & 0xFF00_0000) >> 24) / 255
            g = Double((value & 0x00FF_0000) >> 16) / 255
            b = Double((value & 0x0000_FF00) >> 8) / 255
            a = Double(value & 0x0000_00FF) / 255
        } else {
            r = Double((value & 0xFF0000) >> 16) / 255
            g = Double((value & 0x00FF00) >> 8) / 255
            b = Double(value & 0x0000FF) / 255
            a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

// MARK: - Branded cursor glyph

/// The macOS-style arrow pointer silhouette (adapted from the browser agent
/// cursor in PR #4494), with its tip at the top-left origin so it lands exactly
/// on the reported hotspot. A single `Path` so one gradient fills it seamlessly.
private struct CursorArrowShape: Shape {
    /// Design-space points (top-left origin, y-down), tip normalized to (0,0).
    private static let points: [CGPoint] = [
        CGPoint(x: 0.0, y: 0.0),
        CGPoint(x: 0.0, y: 22.0),
        CGPoint(x: 6.0, y: 16.5),
        CGPoint(x: 9.5, y: 26.5),
        CGPoint(x: 14.5, y: 24.7),
        CGPoint(x: 11.0, y: 14.5),
        CGPoint(x: 18.0, y: 14.5),
    ]
    private static let designSize = CGSize(width: 18, height: 26.5)

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / Self.designSize.width, rect.height / Self.designSize.height)
        var path = Path()
        for (index, point) in Self.points.enumerated() {
            let scaled = CGPoint(x: rect.minX + point.x * scale, y: rect.minY + point.y * scale)
            if index == 0 { path.move(to: scaled) } else { path.addLine(to: scaled) }
        }
        path.closeSubpath()
        return path
    }
}

/// A crisp macOS-style arrow pointer (silhouette from PR #4494) filled with the
/// cmux logo gradient, with a white rim + soft shadow for contrast on any
/// background. No label — just the clean pointer. Pure function of `presentation`.
struct ComputerUseCursorGlyph: View {
    /// Distance from the view's top-left to the arrow tip. Mirrors
    /// `ComputerUseCursorOverlayGeometry.hotspotInset`.
    static let hotspotInset: CGFloat = 22
    private static let pointerSize = CGSize(width: 15, height: 22)

    let presentation: ComputerUseCursorPresentation

    var body: some View {
        pointer
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(EdgeInsets(top: Self.hotspotInset, leading: Self.hotspotInset, bottom: 0, trailing: 0))
    }

    private var pointer: some View {
        CursorArrowShape()
            .fill(
                LinearGradient(
                    colors: presentation.gradientColors,
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                CursorArrowShape()
                    .stroke(Color.white.opacity(0.95), lineWidth: 1.2)
            )
            .frame(width: Self.pointerSize.width, height: Self.pointerSize.height)
            .shadow(color: Color.black.opacity(0.35), radius: 2, x: 0, y: 1)
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
    private var hostingView: NSHostingView<ComputerUseCursorGlyph>?
    private var currentPresentation: ComputerUseCursorPresentation?
    private var directoryWatchSource: DispatchSourceFileSystemObject?
    private let directoryWatchQueue = DispatchQueue(label: "com.cmuxterm.app.computerUseCursorWatch")
    private var pollTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var refreshCoalesceScheduled = false
    private var started = false

    init(
        stateDirectoryURL: URL,
        featureEnabled: @escaping @MainActor () -> Bool,
        feed: ComputerUseCursorFeed = ComputerUseCursorFeed(),
        pollInterval: TimeInterval = 0.75,
        glideDuration: TimeInterval = 0.18
    ) {
        self.stateDirectoryURL = stateDirectoryURL
        self.featureEnabled = featureEnabled
        self.feed = feed
        self.pollInterval = pollInterval
        self.glideDuration = glideDuration
    }

    deinit {
        directoryWatchSource?.cancel()
    }

    func start() {
        guard !started else { return }
        started = true

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
        cancellables.removeAll()
        directoryWatchSource?.cancel()
        directoryWatchSource = nil
        pollTimer?.invalidate()
        pollTimer = nil
        hide(animated: false)
    }

    func refresh() {
        guard featureEnabled() else {
            hide(animated: false)
            return
        }
        guard let state = feed.scan(directoryURL: stateDirectoryURL, now: Date()) else {
            hide(animated: true)
            return
        }
        present(state)
    }

    private func present(_ state: ComputerUseCursorState) {
        guard let primaryMaxY = NSScreen.screens.first?.frame.maxY else { return }
        let presentation = ComputerUseCursorPresentation.make(from: state)
        let panel = ensurePanel()
        if currentPresentation != presentation {
            currentPresentation = presentation
            hostingView?.rootView = ComputerUseCursorGlyph(presentation: presentation)
        }

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
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
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
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.scheduleCoalescedRefresh() }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        directoryWatchSource = source
    }

    /// Coalesce a burst of filesystem events into at most one refresh per frame.
    /// The driver rewrites the cursor feed many times per second while driving;
    /// refreshing on every raw event would flood the main thread with directory
    /// scans and beachball the app during active computer use.
    private func scheduleCoalescedRefresh() {
        guard started, !refreshCoalesceScheduled else { return }
        refreshCoalesceScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 16_000_000)
            guard let self else { return }
            self.refreshCoalesceScheduled = false
            self.refresh()
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let presentation = currentPresentation ?? ComputerUseCursorPresentation(
            gradientHexes: ComputerUseCursorPresentation.defaultGradientHexes,
            bloomHex: ComputerUseCursorPresentation.defaultBloomHex,
            label: ComputerUseCursorPresentation.defaultLabel
        )
        currentPresentation = presentation

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

        let hosting = NSHostingView(rootView: ComputerUseCursorGlyph(presentation: presentation))
        hosting.frame = CGRect(origin: .zero, size: ComputerUseCursorOverlayGeometry.windowSize)
        hosting.autoresizingMask = [.width, .height]
        hosting.setAccessibilityLabel(
            String(
                localized: "computerUse.cursorOverlay.accessibilityLabel",
                defaultValue: "Computer-use cursor"
            )
        )
        panel.contentView = hosting

        self.panel = panel
        self.hostingView = hosting
        return panel
    }
}
