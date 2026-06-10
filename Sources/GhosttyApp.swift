import Foundation
import CmuxTerminalCopyMode
import CmuxSocketControl
import SwiftUI
import AppKit
import Metal
import QuartzCore
import Combine
import CoreText
import Darwin
import Carbon.HIToolbox
import os
import Sentry
import Bonsplit
import CMUXAgentLaunch
import CMUXMobileCore
import CMUXPasteboardFidelity
import IOSurface
import UniformTypeIdentifiers


class GhosttyApp {
    enum ScrollbarVisibility: String {
        case system
        case never
    }

    static let shared = GhosttyApp()
    static let releaseBundleIdentifier = "com.cmuxterm.app"
    static let fallbackAppearanceConfig = GhosttyConfig()
    static let initializationLogger = Logger(
        subsystem: releaseBundleIdentifier,
        category: "ghostty.initialization"
    )
    private static let backgroundLogTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    var app: ghostty_app_t?
    var config: ghostty_config_t?
    /// Coalesce wakeup → tick dispatches.  The I/O thread may fire wakeup_cb
    /// thousands of times per second during bulk output.  We only need one
    /// pending tick on the main queue at any time.
    private var _tickScheduled = false
    private let _tickLock = NSLock()
    var defaultBackgroundColor: NSColor = .windowBackgroundColor
    var defaultBackgroundOpacity: Double = 1.0
    var defaultBackgroundBlur: GhosttyBackgroundBlur = .disabled
    var defaultForegroundColor: NSColor = GhosttyApp.fallbackAppearanceConfig.foregroundColor
    var defaultCursorColor: NSColor = GhosttyApp.fallbackAppearanceConfig.cursorColor
    var defaultCursorTextColor: NSColor = GhosttyApp.fallbackAppearanceConfig.cursorTextColor
    var defaultSelectionBackground: NSColor = GhosttyApp.fallbackAppearanceConfig.selectionBackground
    var defaultSelectionForeground: NSColor = GhosttyApp.fallbackAppearanceConfig.selectionForeground
    var effectiveTerminalColorSchemePreference: GhosttyConfig.ColorSchemePreference = .dark
    var appliedGhosttyRuntimeColorScheme: ghostty_color_scheme_e?
    var runtimeColorSchemeSynchronizationDepth = 0
    var reloadConfigurationDepth = 0
    var usesHostLayerBackground = false
    var userGhosttyShellIntegrationMode: String = "detect"

    static func retainTickNotifications() -> () -> Void {
        GhosttyTickNotificationDemand.retain()
    }

    private static func resolveBackgroundLogURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let explicitPath = environment["CMUX_DEBUG_BG_LOG"],
           !explicitPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: explicitPath)
        }

        if let debugLogPath = environment["CMUX_DEBUG_LOG"],
           !debugLogPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let baseURL = URL(fileURLWithPath: debugLogPath)
            let extensionSeparatorIndex = baseURL.lastPathComponent.lastIndex(of: ".")
            let stem = extensionSeparatorIndex.map { String(baseURL.lastPathComponent[..<$0]) } ?? baseURL.lastPathComponent
            let bgName = "\(stem)-bg.log"
            return baseURL.deletingLastPathComponent().appendingPathComponent(bgName)
        }

        return URL(fileURLWithPath: "/tmp/cmux-bg.log")
    }

#if DEBUG
    static func debugDescription(
        for preparedContent: TerminalImageTransferPreparedContent
    ) -> String {
        switch preparedContent {
        case .insertText(let text):
            return "insertText(length:\(text.utf8.count),hasNewlines:\(text.contains(where: \.isNewline) ? 1 : 0))"
        case .fileURLs(let fileURLs):
            return "fileURLs(count:\(fileURLs.count))"
        case .reject:
            return "reject"
        }
    }
#endif

    let backgroundLogEnabled = {
        if ProcessInfo.processInfo.environment["CMUX_DEBUG_BG"] == "1" {
            return true
        }
        if ProcessInfo.processInfo.environment["CMUX_DEBUG_LOG"] != nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "cmuxDebugBG")
    }()
    private let backgroundLogURL = GhosttyApp.resolveBackgroundLogURL()
    private let backgroundLogStartUptime = ProcessInfo.processInfo.systemUptime
    private let backgroundLogLock = NSLock()
    private var backgroundLogSequence: UInt64 = 0
    var appObservers: [NSObjectProtocol] = []
    var bellAudioSound: NSSound?
    var backgroundEventCounter: UInt64 = 0
    var defaultBackgroundUpdateScope: GhosttyDefaultBackgroundUpdateScope = .unscoped
    var defaultBackgroundScopeSource: String = "initialize"
    var lastAppearanceColorScheme: GhosttyConfig.ColorSchemePreference?
    lazy var defaultBackgroundNotificationDispatcher: GhosttyDefaultBackgroundNotificationDispatcher =
        // Theme chrome should track terminal theme changes in the same frame.
        // Keep coalescing semantics, but flush in the next main turn instead of waiting ~1 frame.
        GhosttyDefaultBackgroundNotificationDispatcher(delay: 0, logEvent: { [weak self] message in
            guard let self, self.backgroundLogEnabled else { return }
            self.logBackground(message)
        })

    // Scroll lag tracking
    private(set) var isScrolling = false
    private var scrollLagSampleCount = 0
    private var scrollLagTotalMs: Double = 0
    private var scrollLagMaxMs: Double = 0
    private let scrollLagThresholdMs: Double = 40
    private let scrollLagMinimumSamples = 8
    private let scrollLagMinimumAverageMs: Double = 12
    private let scrollLagReportCooldownSeconds: TimeInterval = 300
    private var lastScrollLagReportUptime: TimeInterval?
    private var scrollEndTimer: DispatchWorkItem?

    func markScrollActivity(hasMomentum: Bool, momentumEnded: Bool) {
        // Cancel any pending scroll-end timer
        scrollEndTimer?.cancel()
        scrollEndTimer = nil

        if momentumEnded {
            // Trackpad momentum ended - scrolling is done
            endScrollSession()
        } else if hasMomentum {
            // Trackpad scrolling with momentum - wait for momentum to end
            isScrolling = true
        } else {
            // Mouse wheel or non-momentum scroll - use timeout
            isScrolling = true
            let timer = DispatchWorkItem { [weak self] in
                self?.endScrollSession()
            }
            scrollEndTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: timer)
        }
    }

    private func endScrollSession() {
        guard isScrolling else { return }
        isScrolling = false

        // Report accumulated lag stats if any exceeded threshold
        if scrollLagSampleCount > 0 {
            let avgLag = scrollLagTotalMs / Double(scrollLagSampleCount)
            let maxLag = scrollLagMaxMs
            let samples = scrollLagSampleCount
            let threshold = scrollLagThresholdMs
            let nowUptime = ProcessInfo.processInfo.systemUptime
            if Self.shouldCaptureScrollLagEvent(
                samples: samples,
                averageMs: avgLag,
                maxMs: maxLag,
                thresholdMs: threshold,
                minimumSamples: scrollLagMinimumSamples,
                minimumAverageMs: scrollLagMinimumAverageMs,
                nowUptime: nowUptime,
                lastReportedUptime: lastScrollLagReportUptime,
                cooldown: scrollLagReportCooldownSeconds
            ) {
                if TelemetrySettings.enabledForCurrentLaunch {
                    SentrySDK.capture(message: "Scroll lag detected") { scope in
                        scope.setLevel(.warning)
                        scope.setContext(value: [
                            "samples": samples,
                            "avg_ms": String(format: "%.2f", avgLag),
                            "max_ms": String(format: "%.2f", maxLag),
                            "threshold_ms": threshold
                        ], key: "scroll_lag")
                    }
                }
                lastScrollLagReportUptime = nowUptime
            }
            // Reset stats
            scrollLagSampleCount = 0
            scrollLagTotalMs = 0
            scrollLagMaxMs = 0
        }
    }

    private init() {
        initializeGhostty()
    }

    static func shouldCaptureScrollLagEvent(
        samples: Int,
        averageMs: Double,
        maxMs: Double,
        thresholdMs: Double,
        minimumSamples: Int = 8,
        minimumAverageMs: Double = 12,
        nowUptime: TimeInterval,
        lastReportedUptime: TimeInterval?,
        cooldown: TimeInterval = 300
    ) -> Bool {
        guard samples >= minimumSamples else { return false }
        guard averageMs.isFinite, maxMs.isFinite, thresholdMs.isFinite, nowUptime.isFinite, cooldown.isFinite else {
            return false
        }
        guard averageMs >= minimumAverageMs else { return false }
        guard maxMs > thresholdMs else { return false }
        if let lastReportedUptime, nowUptime - lastReportedUptime < cooldown {
            return false
        }
        return true
    }

    /// Schedule a single tick on the main queue, coalescing multiple wakeups.
    func scheduleTick() {
        _tickLock.lock()
        defer { _tickLock.unlock() }
        guard !_tickScheduled else { return }
        _tickScheduled = true
        DispatchQueue.main.async {
            self.tick()
        }
    }

    func tick() {
        _tickLock.lock()
        _tickScheduled = false
        _tickLock.unlock()

        guard let app = app else { return }

        let start = CACurrentMediaTime()
        ghostty_app_tick(app)
        let elapsedMs = (CACurrentMediaTime() - start) * 1000
        if GhosttyTickNotificationDemand.isActive {
            NotificationCenter.default.post(name: .ghosttyDidTick, object: self)
        }

        // Track lag during scrolling
        if isScrolling {
            scrollLagSampleCount += 1
            scrollLagTotalMs += elapsedMs
            scrollLagMaxMs = max(scrollLagMaxMs, elapsedMs)
        }
    }

    func focusFollowsMouseEnabled() -> Bool {
        guard let config else { return false }
        var enabled = false
        let key = "focus-follows-mouse"
        let keyLength = UInt(key.lengthOfBytes(using: .utf8))
        let found = ghostty_config_get(config, &enabled, key, keyLength)
        return found && enabled
    }

    func scrollbarVisibility() -> ScrollbarVisibility {
        guard let config else { return .system }
        var value: UnsafePointer<Int8>?
        let key = "scrollbar"
        guard ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8))),
              let value else {
            return .system
        }
        return ScrollbarVisibility(rawValue: String(cString: value)) ?? .system
    }

    func appleScriptAutomationEnabled() -> Bool {
        guard let config else { return false }
        var enabled = false
        let key = "macos-applescript"
        _ = ghostty_config_get(config, &enabled, key, UInt(key.lengthOfBytes(using: .utf8)))
        return enabled
    }

    func logBackground(_ message: String) {
        let timestamp = Self.backgroundLogTimestampFormatter.string(from: Date())
        let uptimeMs = (ProcessInfo.processInfo.systemUptime - backgroundLogStartUptime) * 1000
        let frame60 = Int((CACurrentMediaTime() * 60.0).rounded(.down))
        let frame120 = Int((CACurrentMediaTime() * 120.0).rounded(.down))
        let threadLabel = Thread.isMainThread ? "main" : "background"
        backgroundLogLock.lock()
        defer { backgroundLogLock.unlock() }
        backgroundLogSequence &+= 1
        let sequence = backgroundLogSequence
        let line =
            "\(timestamp) seq=\(sequence) t+\(String(format: "%.3f", uptimeMs))ms thread=\(threadLabel) frame60=\(frame60) frame120=\(frame120) cmux bg: \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: backgroundLogURL.path) == false {
                FileManager.default.createFile(atPath: backgroundLogURL.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: backgroundLogURL) {
                defer { try? handle.close() }
                guard (try? handle.seekToEnd()) != nil else { return }
                try? handle.write(contentsOf: data)
            }
        }
    }
}

// MARK: - Debug Render Instrumentation

private enum GhosttyTickNotificationDemand {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var count = 0

    static func retain() -> () -> Void {
        lock.lock()
        count += 1
        lock.unlock()

        return {
            lock.lock()
            count = max(0, count - 1)
            lock.unlock()
        }
    }

    static var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return count > 0
    }
}

