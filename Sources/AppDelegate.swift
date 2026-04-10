import AppKit
import SwiftUI
import Bonsplit
import CoreServices
import UserNotifications
import Sentry
import WebKit
import Combine
import ObjectiveC.runtime
import Darwin

final class MainWindowHostingView<Content: View>: NSHostingView<Content> {
    private let zeroSafeAreaLayoutGuide = NSLayoutGuide()

    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override var safeAreaRect: NSRect { bounds }
    override var safeAreaLayoutGuide: NSLayoutGuide { zeroSafeAreaLayoutGuide }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        addLayoutGuide(zeroSafeAreaLayoutGuide)
        NSLayoutConstraint.activate([
            zeroSafeAreaLayoutGuide.leadingAnchor.constraint(equalTo: leadingAnchor),
            zeroSafeAreaLayoutGuide.trailingAnchor.constraint(equalTo: trailingAnchor),
            zeroSafeAreaLayoutGuide.topAnchor.constraint(equalTo: topAnchor),
            zeroSafeAreaLayoutGuide.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private enum CmuxThemeNotifications {
    static let reloadConfig = Notification.Name("com.cmuxterm.themes.reload-config")
}

func isCommandPaletteFocusStealingTerminalOrBrowserResponder(_ responder: NSResponder) -> Bool {
    if responder is GhosttyNSView || responder is WKWebView {
        return true
    }

    if let textView = responder as? NSTextView, !textView.isFieldEditor {
        if let delegateView = textView.delegate as? NSView,
           isCommandPaletteFocusStealingTerminalOrBrowserView(delegateView) {
            return true
        }
        return isCommandPaletteFocusStealingTerminalOrBrowserView(textView)
    }

    if let view = responder as? NSView {
        return isCommandPaletteFocusStealingTerminalOrBrowserView(view)
    }

    return false
}

func isCommandPaletteFocusStealingTerminalOrBrowserView(_ view: NSView) -> Bool {
    if view is GhosttyNSView || view is GhosttySurfaceScrollView || view is WKWebView {
        return true
    }
    var current: NSView? = view.superview
    while let candidate = current {
        if candidate is GhosttyNSView || candidate is GhosttySurfaceScrollView || candidate is WKWebView {
            return true
        }
        current = candidate.superview
    }
    return false
}

#if DEBUG
enum CmuxTypingTiming {
    static let isEnabled: Bool = {
        let environment = ProcessInfo.processInfo.environment
        if environment["CMUX_TYPING_TIMING_LOGS"] == "1" || environment["CMUX_KEY_LATENCY_PROBE"] == "1" {
            return true
        }
        let defaults = UserDefaults.standard
        return defaults.bool(forKey: "cmuxTypingTimingLogs") || defaults.bool(forKey: "cmuxKeyLatencyProbe")
    }()
    static let isVerboseProbeEnabled: Bool = {
        let environment = ProcessInfo.processInfo.environment
        if environment["CMUX_KEY_LATENCY_PROBE"] == "1" {
            return true
        }
        return UserDefaults.standard.bool(forKey: "cmuxKeyLatencyProbe")
    }()
    private static let delayLogThresholdMs: Double = 6.0
    private static let durationLogThresholdMs: Double = 1.0

    @inline(__always)
    static func start() -> TimeInterval? {
        guard isEnabled else { return nil }
        return ProcessInfo.processInfo.systemUptime
    }

    @inline(__always)
    static func logEventDelay(path: String, event: NSEvent) {
        guard isEnabled else { return }
        guard event.timestamp > 0 else { return }
        let delayMs = max(0, (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000.0)
        guard shouldLog(delayMs: delayMs, elapsedMs: nil) else { return }
        dlog("typing.delay path=\(path) delayMs=\(format(delayMs)) \(eventFields(event))")
    }

    @inline(__always)
    static func logDuration(path: String, startedAt: TimeInterval?, event: NSEvent? = nil, extra: String? = nil) {
        CmuxMainThreadTurnProfiler.endMeasure(path, startedAt: startedAt)
        guard let startedAt else { return }
        let elapsedMs = max(0, (ProcessInfo.processInfo.systemUptime - startedAt) * 1000.0)
        let delayMs: Double? = {
            guard let event, event.timestamp > 0 else { return nil }
            return max(0, (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000.0)
        }()
        guard shouldLog(delayMs: delayMs, elapsedMs: elapsedMs) else { return }
        var line = "typing.timing path=\(path) elapsedMs=\(format(elapsedMs))"
        if let event {
            line += " \(eventFields(event))"
            if let delayMs {
                line += " delayMs=\(format(delayMs))"
            }
        }
        if let extra, !extra.isEmpty {
            line += " \(extra)"
        }
        dlog(line)
    }

    @inline(__always)
    static func logBreakdown(
        path: String,
        totalMs: Double,
        event: NSEvent? = nil,
        thresholdMs: Double = 2.0,
        parts: [(String, Double)],
        extra: String? = nil
    ) {
        guard isEnabled else { return }
        let delayMs: Double? = {
            guard let event, event.timestamp > 0 else { return nil }
            return max(0, (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000.0)
        }()
        let hasSlowPart = parts.contains { $0.1 >= thresholdMs }
        guard isVerboseProbeEnabled || totalMs >= thresholdMs || hasSlowPart || (delayMs ?? 0) >= delayLogThresholdMs else {
            return
        }
        var line = "typing.phase path=\(path) totalMs=\(format(totalMs))"
        if let event {
            line += " \(eventFields(event))"
        }
        if let delayMs {
            line += " delayMs=\(format(delayMs))"
        }
        for (name, value) in parts where isVerboseProbeEnabled || value >= 0.05 {
            line += " \(name)=\(format(value))"
        }
        if let extra, !extra.isEmpty {
            line += " \(extra)"
        }
        dlog(line)
    }

    @inline(__always)
    private static func eventFields(_ event: NSEvent) -> String {
        "eventType=\(event.type.rawValue) keyCode=\(event.keyCode) mods=\(event.modifierFlags.rawValue) repeat=\(event.isARepeat ? 1 : 0)"
    }

    @inline(__always)
    private static func shouldLog(delayMs: Double?, elapsedMs: Double?) -> Bool {
        if isVerboseProbeEnabled {
            return true
        }
        if let delayMs, delayMs >= delayLogThresholdMs {
            return true
        }
        if let elapsedMs, elapsedMs >= durationLogThresholdMs {
            return true
        }
        return false
    }

    @inline(__always)
    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

final class CmuxMainRunLoopStallMonitor {
    static let shared = CmuxMainRunLoopStallMonitor()

    private let thresholdMs: Double = 8.0
    private var observer: CFRunLoopObserver?
    private var installed = false
    private var lastActivity: CFRunLoopActivity?
    private var lastTimestamp: TimeInterval?

    private init() {}

    func installIfNeeded() {
        guard CmuxTypingTiming.isEnabled else { return }
        guard !installed else { return }

        var context = CFRunLoopObserverContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        observer = CFRunLoopObserverCreate(
            kCFAllocatorDefault,
            CFRunLoopActivity.allActivities.rawValue,
            true,
            CFIndex.max,
            { _, activity, info in
                guard let info else { return }
                let monitor = Unmanaged<CmuxMainRunLoopStallMonitor>.fromOpaque(info).takeUnretainedValue()
                monitor.handle(activity: activity)
            },
            &context
        )

        guard let observer else { return }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        installed = true
    }

    private func handle(activity: CFRunLoopActivity) {
        let now = ProcessInfo.processInfo.systemUptime
        defer {
            lastActivity = activity
            lastTimestamp = now
        }

        guard let lastActivity, let lastTimestamp else { return }
        let elapsedMs = max(0, (now - lastTimestamp) * 1000.0)
        guard elapsedMs >= thresholdMs else { return }
        if lastActivity == .beforeWaiting && activity == .afterWaiting {
            return
        }

        let mode = CFRunLoopCopyCurrentMode(CFRunLoopGetMain()).map { String(describing: $0) } ?? "nil"
        let firstResponder = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let currentEvent = NSApp.currentEvent.map {
            "eventType=\($0.type.rawValue) keyCode=\($0.keyCode) mods=\($0.modifierFlags.rawValue)"
        } ?? "event=nil"
        dlog(
            "runloop.stall gapMs=\(String(format: "%.2f", elapsedMs)) prev=\(label(for: lastActivity)) " +
            "next=\(label(for: activity)) mode=\(mode) firstResponder=\(firstResponder) \(currentEvent)"
        )
    }

    private func label(for activity: CFRunLoopActivity) -> String {
        switch activity {
        case .entry:
            return "entry"
        case .beforeTimers:
            return "beforeTimers"
        case .beforeSources:
            return "beforeSources"
        case .beforeWaiting:
            return "beforeWaiting"
        case .afterWaiting:
            return "afterWaiting"
        case .exit:
            return "exit"
        default:
            return "unknown(\(activity.rawValue))"
        }
    }
}

final class CmuxMainThreadTurnProfiler {
    static let shared = CmuxMainThreadTurnProfiler()

    private struct BucketStats {
        var count: Int = 0
        var totalMs: Double = 0
        var maxMs: Double = 0
    }

    private let trackedThresholdMs: Double = 3.0
    private let countThreshold: Int = 16
    private var observer: CFRunLoopObserver?
    private var installed = false
    private var turnStart: TimeInterval?
    private var buckets: [String: BucketStats] = [:]

    private init() {}

    @inline(__always)
    static func endMeasure(_ bucket: String, startedAt: TimeInterval?) {
        guard let startedAt, CmuxTypingTiming.isEnabled, Thread.isMainThread else { return }
        let elapsedMs = max(0, (ProcessInfo.processInfo.systemUptime - startedAt) * 1000.0)
        shared.record(bucket: bucket, elapsedMs: elapsedMs, count: 1)
    }

    func installIfNeeded() {
        guard CmuxTypingTiming.isEnabled else { return }
        guard !installed else { return }

        var context = CFRunLoopObserverContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        observer = CFRunLoopObserverCreate(
            kCFAllocatorDefault,
            CFRunLoopActivity.allActivities.rawValue,
            true,
            CFIndex.max,
            { _, activity, info in
                guard let info else { return }
                let profiler = Unmanaged<CmuxMainThreadTurnProfiler>.fromOpaque(info).takeUnretainedValue()
                profiler.handle(activity: activity)
            },
            &context
        )

        guard let observer else { return }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        installed = true
    }

    private func handle(activity: CFRunLoopActivity) {
        let now = ProcessInfo.processInfo.systemUptime
        switch activity {
        case .entry, .afterWaiting:
            turnStart = now
            buckets.removeAll(keepingCapacity: true)
        case .beforeWaiting, .exit:
            flushTurn(at: now, nextActivity: activity)
        default:
            break
        }
    }

    private func record(bucket: String, elapsedMs: Double, count: Int) {
        if turnStart == nil {
            turnStart = ProcessInfo.processInfo.systemUptime
        }
        var stats = buckets[bucket, default: BucketStats()]
        stats.count += count
        stats.totalMs += elapsedMs
        stats.maxMs = max(stats.maxMs, elapsedMs)
        buckets[bucket] = stats
    }

    private func flushTurn(at now: TimeInterval, nextActivity: CFRunLoopActivity) {
        defer {
            turnStart = nil
            buckets.removeAll(keepingCapacity: true)
        }

        guard let turnStart else { return }
        guard !buckets.isEmpty else { return }

        let turnMs = max(0, (now - turnStart) * 1000.0)
        let trackedMs = buckets.values.reduce(0) { $0 + $1.totalMs }
        let totalCount = buckets.values.reduce(0) { $0 + $1.count }
        guard trackedMs >= trackedThresholdMs || totalCount >= countThreshold else { return }

        let mode = CFRunLoopCopyCurrentMode(CFRunLoopGetMain()).map { String(describing: $0) } ?? "nil"
        let firstResponder = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let eventSummary = NSApp.currentEvent.map {
            "eventType=\($0.type.rawValue) keyCode=\($0.keyCode) mods=\($0.modifierFlags.rawValue)"
        } ?? "event=nil"
        let bucketSummary = buckets
            .sorted {
                if abs($0.value.totalMs - $1.value.totalMs) > 0.01 {
                    return $0.value.totalMs > $1.value.totalMs
                }
                return $0.value.count > $1.value.count
            }
            .prefix(8)
            .map { key, value in
                if value.totalMs > 0.05 || value.maxMs > 0.05 {
                    return "\(key)=\(value.count)/\(String(format: "%.2f", value.totalMs))/\(String(format: "%.2f", value.maxMs))"
                }
                return "\(key)=\(value.count)"
            }
            .joined(separator: " ")

        dlog(
            "main.turn.work turnMs=\(String(format: "%.2f", turnMs)) trackedMs=\(String(format: "%.2f", trackedMs)) totalCount=\(totalCount) " +
            "next=\(label(for: nextActivity)) mode=\(mode) firstResponder=\(firstResponder) \(eventSummary) " +
            "\(bucketSummary)"
        )
    }

    private func label(for activity: CFRunLoopActivity) -> String {
        switch activity {
        case .entry:
            return "entry"
        case .beforeTimers:
            return "beforeTimers"
        case .beforeSources:
            return "beforeSources"
        case .beforeWaiting:
            return "beforeWaiting"
        case .afterWaiting:
            return "afterWaiting"
        case .exit:
            return "exit"
        default:
            return "unknown(\(activity.rawValue))"
        }
    }
}
#endif

enum FinderServicePathResolver {
    private static func canonicalDirectoryPath(_ path: String) -> String {
        guard path.count > 1 else { return path }
        var canonical = path
        while canonical.count > 1 && canonical.hasSuffix("/") {
            canonical.removeLast()
        }
        return canonical
    }

    private static func normalizedComparisonURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func isSameOrDescendant(_ url: URL, of rootURL: URL) -> Bool {
        let urlPathComponents = normalizedComparisonURL(url).pathComponents
        let rootPathComponents = normalizedComparisonURL(rootURL).pathComponents
        guard urlPathComponents.count >= rootPathComponents.count else { return false }
        return Array(urlPathComponents.prefix(rootPathComponents.count)) == rootPathComponents
    }

    private static func resolvedDirectoryURL(from url: URL) -> URL {
        let standardized = url.standardizedFileURL
        if standardized.hasDirectoryPath {
            return standardized
        }
        if let resourceValues = try? standardized.resourceValues(forKeys: [.isDirectoryKey]),
           resourceValues.isDirectory == true {
            return standardized
        }
        return standardized.deletingLastPathComponent()
    }

    static func orderedUniqueDirectories(
        from pathURLs: [URL],
        excludingDescendantsOf excludedRootURLs: [URL] = []
    ) -> [String] {
        var seen: Set<String> = []
        var directories: [String] = []

        for url in pathURLs {
            let directoryURL = resolvedDirectoryURL(from: url)
            guard !excludedRootURLs.contains(where: { isSameOrDescendant(directoryURL, of: $0) }) else {
                continue
            }
            let path = canonicalDirectoryPath(directoryURL.path(percentEncoded: false))
            guard !path.isEmpty else { continue }
            if seen.insert(path).inserted {
                directories.append(path)
            }
        }

        return directories
    }
}

enum TerminalDirectoryOpenTarget: String, CaseIterable {
    case androidStudio
    case antigravity
    case cursor
    case finder
    case ghostty
    case intellij
    case iterm2
    case terminal
    case tower
    case vscode
    case vscodeInline
    case warp
    case windsurf
    case xcode
    case zed

    struct DetectionEnvironment {
        let homeDirectoryPath: String
        let fileExistsAtPath: (String) -> Bool
        let isExecutableFileAtPath: (String) -> Bool
        let applicationPathForName: (String) -> String?

        static let live = DetectionEnvironment(
            homeDirectoryPath: FileManager.default.homeDirectoryForCurrentUser.path,
            fileExistsAtPath: { FileManager.default.fileExists(atPath: $0) },
            isExecutableFileAtPath: { FileManager.default.isExecutableFile(atPath: $0) },
            applicationPathForName: { NSWorkspace.shared.fullPath(forApplication: $0) }
        )
    }

    static var commandPaletteShortcutTargets: [Self] {
        Array(allCases)
    }

    static func availableTargets(in environment: DetectionEnvironment = .live) -> Set<Self> {
        Set(commandPaletteShortcutTargets.filter { $0.isAvailable(in: environment) })
    }

    var commandPaletteCommandId: String {
        "palette.terminalOpenDirectory.\(rawValue)"
    }

    var commandPaletteTitle: String {
        switch self {
        case .androidStudio:
            return String(localized: "menu.openInAndroidStudio", defaultValue: "Open Current Directory in Android Studio")
        case .antigravity:
            return String(localized: "menu.openInAntigravity", defaultValue: "Open Current Directory in Antigravity")
        case .cursor:
            return String(localized: "menu.openInCursor", defaultValue: "Open Current Directory in Cursor")
        case .finder:
            return String(localized: "menu.openInFinder", defaultValue: "Open Current Directory in Finder")
        case .ghostty:
            return String(localized: "menu.openInGhostty", defaultValue: "Open Current Directory in Ghostty")
        case .intellij:
            return String(localized: "menu.openInIntelliJ", defaultValue: "Open Current Directory in IntelliJ IDEA")
        case .iterm2:
            return String(localized: "menu.openInITerm2", defaultValue: "Open Current Directory in iTerm2")
        case .terminal:
            return String(localized: "menu.openInTerminal", defaultValue: "Open Current Directory in Terminal")
        case .tower:
            return String(localized: "menu.openInTower", defaultValue: "Open Current Directory in Tower")
        case .vscode:
            return String(localized: "menu.openInVSCodeDesktop", defaultValue: "Open Current Directory in VS Code")
        case .vscodeInline:
            return String(localized: "menu.openInVSCode", defaultValue: "Open Current Directory in VS Code (Inline)")
        case .warp:
            return String(localized: "menu.openInWarp", defaultValue: "Open Current Directory in Warp")
        case .windsurf:
            return String(localized: "menu.openInWindsurf", defaultValue: "Open Current Directory in Windsurf")
        case .xcode:
            return String(localized: "menu.openInXcode", defaultValue: "Open Current Directory in Xcode")
        case .zed:
            return String(localized: "menu.openInZed", defaultValue: "Open Current Directory in Zed")
        }
    }

    var commandPaletteKeywords: [String] {
        let common = ["terminal", "directory", "open", "ide"]
        switch self {
        case .androidStudio:
            return common + ["android", "studio"]
        case .antigravity:
            return common + ["antigravity"]
        case .cursor:
            return common + ["cursor"]
        case .finder:
            return common + ["finder", "file", "manager", "reveal"]
        case .ghostty:
            return common + ["ghostty", "terminal", "shell"]
        case .intellij:
            return common + ["intellij", "idea", "jetbrains"]
        case .iterm2:
            return common + ["iterm", "iterm2", "terminal", "shell"]
        case .terminal:
            return common + ["terminal", "shell"]
        case .tower:
            return common + ["tower", "git", "client"]
        case .vscode:
            return common + ["vs", "code", "visual", "studio", "desktop", "app"]
        case .vscodeInline:
            return common + ["vs", "code", "visual", "studio", "inline", "browser", "serve-web"]
        case .warp:
            return common + ["warp", "terminal", "shell"]
        case .windsurf:
            return common + ["windsurf"]
        case .xcode:
            return common + ["xcode", "apple"]
        case .zed:
            return common + ["zed"]
        }
    }

    func isAvailable(in environment: DetectionEnvironment = .live) -> Bool {
        guard let applicationPath = applicationPath(in: environment) else { return false }
        guard self == .vscodeInline else { return true }
        return VSCodeCLILaunchConfigurationBuilder.launchConfiguration(
            vscodeApplicationURL: URL(fileURLWithPath: applicationPath, isDirectory: true),
            isExecutableAtPath: environment.isExecutableFileAtPath
        ) != nil
    }

    func applicationURL(in environment: DetectionEnvironment = .live) -> URL? {
        guard let path = applicationPath(in: environment) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func applicationPath(in environment: DetectionEnvironment) -> String? {
        for path in expandedCandidatePaths(in: environment) where environment.fileExistsAtPath(path) {
            return path
        }

        // Fall back to LaunchServices so apps outside the standard bundle paths
        // still appear in the command palette.
        for applicationName in applicationSearchNames {
            guard let resolvedPath = environment.applicationPathForName(applicationName),
                  environment.fileExistsAtPath(resolvedPath) else {
                continue
            }
            return resolvedPath
        }

        return nil
    }

    private func expandedCandidatePaths(in environment: DetectionEnvironment) -> [String] {
        let globalPrefix = "/Applications/"
        let userPrefix = "\(environment.homeDirectoryPath)/Applications/"
        var expanded: [String] = []

        for candidate in applicationBundlePathCandidates {
            expanded.append(candidate)
            if candidate.hasPrefix(globalPrefix) {
                let suffix = String(candidate.dropFirst(globalPrefix.count))
                expanded.append(userPrefix + suffix)
            }
        }

        return uniquePreservingOrder(expanded)
    }

    private var applicationSearchNames: [String] {
        uniquePreservingOrder(
            applicationBundlePathCandidates.map {
                URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
            }
        )
    }

    private var applicationBundlePathCandidates: [String] {
        switch self {
        case .androidStudio:
            return ["/Applications/Android Studio.app"]
        case .antigravity:
            return ["/Applications/Antigravity.app"]
        case .cursor:
            return [
                "/Applications/Cursor.app",
                "/Applications/Cursor Preview.app",
                "/Applications/Cursor Nightly.app",
            ]
        case .finder:
            return ["/System/Library/CoreServices/Finder.app"]
        case .ghostty:
            return ["/Applications/Ghostty.app"]
        case .intellij:
            return ["/Applications/IntelliJ IDEA.app"]
        case .iterm2:
            return [
                "/Applications/iTerm.app",
                "/Applications/iTerm2.app",
            ]
        case .terminal:
            return ["/System/Applications/Utilities/Terminal.app"]
        case .tower:
            return ["/Applications/Tower.app"]
        case .vscode:
            return [
                "/Applications/Visual Studio Code.app",
                "/Applications/Code.app",
            ]
        case .vscodeInline:
            return [
                "/Applications/Visual Studio Code.app",
                "/Applications/Code.app",
            ]
        case .warp:
            return ["/Applications/Warp.app"]
        case .windsurf:
            return ["/Applications/Windsurf.app"]
        case .xcode:
            return ["/Applications/Xcode.app"]
        case .zed:
            return [
                "/Applications/Zed.app",
                "/Applications/Zed Preview.app",
                "/Applications/Zed Nightly.app",
            ]
        }
    }

    private func uniquePreservingOrder(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        var deduped: [String] = []
        for path in paths where seen.insert(path).inserted {
            deduped.append(path)
        }
        return deduped
    }
}

enum VSCodeServeWebURLBuilder {
    static func extractWebUIURL(from output: String) -> URL? {
        let prefix = "Web UI available at "
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            guard let range = line.range(of: prefix) else { continue }
            let rawURL = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawURL.isEmpty, let url = URL(string: rawURL) else { continue }
            return url
        }
        return nil
    }

    static func openFolderURL(baseWebUIURL: URL, directoryPath: String) -> URL? {
        var components = URLComponents(url: baseWebUIURL, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.removeAll { $0.name == "folder" }
        queryItems.append(URLQueryItem(name: "folder", value: directoryPath))
        components?.queryItems = queryItems
        return components?.url
    }
}

struct VSCodeCLILaunchConfiguration {
    let executableURL: URL
    let argumentsPrefix: [String]
    let environment: [String: String]
}

enum VSCodeCLILaunchConfigurationBuilder {
    static func launchConfiguration(
        vscodeApplicationURL: URL,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutableAtPath: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> VSCodeCLILaunchConfiguration? {
        let contentsURL = vscodeApplicationURL.appendingPathComponent("Contents", isDirectory: true)
        let codeTunnelURL = contentsURL.appendingPathComponent("Resources/app/bin/code-tunnel", isDirectory: false)
        guard isExecutableAtPath(codeTunnelURL.path) else { return nil }

        var environment = baseEnvironment
        environment["ELECTRON_RUN_AS_NODE"] = "1"
        environment.removeValue(forKey: "VSCODE_NODE_OPTIONS")
        environment.removeValue(forKey: "VSCODE_NODE_REPL_EXTERNAL_MODULE")
        if let nodeOptions = environment["NODE_OPTIONS"] {
            environment["VSCODE_NODE_OPTIONS"] = nodeOptions
        }
        if let nodeReplExternalModule = environment["NODE_REPL_EXTERNAL_MODULE"] {
            environment["VSCODE_NODE_REPL_EXTERNAL_MODULE"] = nodeReplExternalModule
        }
        environment.removeValue(forKey: "NODE_OPTIONS")
        environment.removeValue(forKey: "NODE_REPL_EXTERNAL_MODULE")

        return VSCodeCLILaunchConfiguration(
            executableURL: codeTunnelURL,
            argumentsPrefix: [],
            environment: environment
        )
    }
}

final class VSCodeServeWebController {
    static let shared = VSCodeServeWebController()
    private static let serveWebStartupTimeoutSeconds: TimeInterval = 60

    private let queue = DispatchQueue(label: "cmux.vscode.serveWeb")
    private let launchQueue = DispatchQueue(label: "cmux.vscode.serveWeb.launch")
    private let launchProcessOverride: ((URL, UInt64) -> (process: Process, url: URL)?)?
    private var serveWebProcess: Process?
    private var launchingProcess: Process?
    private var connectionTokenFilesByProcessID: [ObjectIdentifier: URL] = [:]
    private var serveWebURL: URL?
    private var pendingCompletions: [(generation: UInt64, completion: (URL?) -> Void)] = []
    private var isLaunching = false
    private var activeLaunchGeneration: UInt64?
    private var lifecycleGeneration: UInt64 = 0
#if DEBUG
    private var testingTrackedProcesses: [Process] = []
#endif

    private init(launchProcessOverride: ((URL, UInt64) -> (process: Process, url: URL)?)? = nil) {
        self.launchProcessOverride = launchProcessOverride
    }

#if DEBUG
    static func makeForTesting(
        launchProcessOverride: @escaping (URL, UInt64) -> (process: Process, url: URL)?
    ) -> VSCodeServeWebController {
        VSCodeServeWebController(launchProcessOverride: launchProcessOverride)
    }

    func trackConnectionTokenFileForTesting(
        _ connectionTokenFileURL: URL,
        setAsLaunchingProcess: Bool = false,
        setAsServeWebProcess: Bool = false
    ) {
        let process = Process()
        queue.sync {
            if setAsLaunchingProcess {
                self.launchingProcess = process
            }
            if setAsServeWebProcess {
                self.serveWebProcess = process
            }
            if !setAsLaunchingProcess && !setAsServeWebProcess {
                self.testingTrackedProcesses.append(process)
            }
            self.connectionTokenFilesByProcessID[ObjectIdentifier(process)] = connectionTokenFileURL
        }
    }
#endif

    func ensureServeWebURL(vscodeApplicationURL: URL, completion: @escaping (URL?) -> Void) {
        queue.async {
            if let process = self.serveWebProcess,
               process.isRunning,
               let url = self.serveWebURL {
                DispatchQueue.main.async {
                    completion(url)
                }
                return
            }

            let completionGeneration = self.lifecycleGeneration
            self.pendingCompletions.append((generation: completionGeneration, completion: completion))
            guard !self.isLaunching else { return }

            self.isLaunching = true
            let launchGeneration = completionGeneration
            self.activeLaunchGeneration = launchGeneration

            self.launchQueue.async {
                let shouldLaunch = self.queue.sync {
                    self.lifecycleGeneration == launchGeneration
                }
                guard shouldLaunch else {
                    self.queue.async {
                        guard self.activeLaunchGeneration == launchGeneration else { return }
                        self.isLaunching = false
                        self.activeLaunchGeneration = nil
                    }
                    return
                }
                let launchResult = self.launchServeWebProcess(
                    vscodeApplicationURL: vscodeApplicationURL,
                    expectedGeneration: launchGeneration
                )
                self.queue.async {
                    guard self.activeLaunchGeneration == launchGeneration else {
                        if let process = launchResult?.process, process.isRunning {
                            process.terminate()
                        }
                        return
                    }
                    self.isLaunching = false
                    self.activeLaunchGeneration = nil

                    guard self.lifecycleGeneration == launchGeneration else {
                        if let launchedProcess = launchResult?.process,
                           self.launchingProcess === launchedProcess {
                            self.launchingProcess = nil
                        }
                        if let process = launchResult?.process, process.isRunning {
                            process.terminate()
                        }
                        return
                    }

                    if let launchResult {
                        self.launchingProcess = nil
                        self.serveWebProcess = launchResult.process
                        self.serveWebURL = launchResult.url
                    } else {
                        self.launchingProcess = nil
                        self.serveWebProcess = nil
                        self.serveWebURL = nil
                    }

                    var completions: [(URL?) -> Void] = []
                    var remaining: [(generation: UInt64, completion: (URL?) -> Void)] = []
                    for pending in self.pendingCompletions {
                        if pending.generation == launchGeneration {
                            completions.append(pending.completion)
                        } else {
                            remaining.append(pending)
                        }
                    }
                    self.pendingCompletions = remaining
                    let resolvedURL = self.serveWebURL
                    DispatchQueue.main.async {
                        completions.forEach { $0(resolvedURL) }
                    }
                }
            }
        }
    }

    func stop() {
        let (processes, tokenFileURLs, completions): ([Process], [URL], [(URL?) -> Void]) = queue.sync {
            self.lifecycleGeneration &+= 1
            self.isLaunching = false
            self.activeLaunchGeneration = nil
            var processes: [Process] = []
            if let process = self.serveWebProcess {
                processes.append(process)
            }
            if let process = self.launchingProcess,
               !processes.contains(where: { $0 === process }) {
                processes.append(process)
            }
            self.serveWebProcess = nil
            self.launchingProcess = nil
#if DEBUG
            self.testingTrackedProcesses.removeAll()
#endif
            var tokenFileURLs = processes.compactMap {
                self.connectionTokenFilesByProcessID.removeValue(forKey: ObjectIdentifier($0))
            }
            tokenFileURLs.append(contentsOf: self.connectionTokenFilesByProcessID.values)
            self.connectionTokenFilesByProcessID.removeAll()
            self.serveWebURL = nil
            let completions = self.pendingCompletions.map(\.completion)
            self.pendingCompletions.removeAll()
            return (processes, tokenFileURLs, completions)
        }

        for tokenFileURL in tokenFileURLs {
            Self.removeConnectionTokenFile(at: tokenFileURL)
        }

        for process in processes where process.isRunning {
            process.terminate()
        }

        if !completions.isEmpty {
            DispatchQueue.main.async {
                completions.forEach { $0(nil) }
            }
        }
    }

    func restart(vscodeApplicationURL: URL, completion: @escaping (URL?) -> Void) {
        stop()
        ensureServeWebURL(vscodeApplicationURL: vscodeApplicationURL, completion: completion)
    }

    private func launchServeWebProcess(
        vscodeApplicationURL: URL,
        expectedGeneration: UInt64
    ) -> (process: Process, url: URL)? {
        if let launchProcessOverride {
            return launchProcessOverride(vscodeApplicationURL, expectedGeneration)
        }

        guard let launchConfiguration = VSCodeCLILaunchConfigurationBuilder.launchConfiguration(
            vscodeApplicationURL: vscodeApplicationURL
        ) else { return nil }

        guard let connectionTokenFileURL = Self.makeConnectionTokenFile() else {
            return nil
        }

        let process = Process()
        process.executableURL = launchConfiguration.executableURL
        process.arguments = launchConfiguration.argumentsPrefix + [
            "serve-web",
            "--accept-server-license-terms",
            "--host", "127.0.0.1",
            "--port", "0",
            "--connection-token-file", connectionTokenFileURL.path,
        ]
        process.environment = launchConfiguration.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let collector = ServeWebOutputCollector()
        let outputReader: (FileHandle) -> Void = { fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else { return }
            collector.append(data)
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = outputReader
        stderrPipe.fileHandleForReading.readabilityHandler = outputReader

        process.terminationHandler = { [weak self] terminatedProcess in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            Self.drainAvailableOutput(from: stdoutPipe.fileHandleForReading, collector: collector)
            Self.drainAvailableOutput(from: stderrPipe.fileHandleForReading, collector: collector)
            collector.markProcessExited()
            self?.queue.async {
                guard let self else { return }
                if self.launchingProcess === terminatedProcess {
                    self.launchingProcess = nil
                }
                if self.serveWebProcess === terminatedProcess {
                    self.serveWebProcess = nil
                    self.serveWebURL = nil
                }
                if let tokenFileURL = self.connectionTokenFilesByProcessID.removeValue(
                    forKey: ObjectIdentifier(terminatedProcess)
                ) {
                    Self.removeConnectionTokenFile(at: tokenFileURL)
                }
            }
        }

        let didStart: Bool = queue.sync {
            guard self.lifecycleGeneration == expectedGeneration,
                  self.activeLaunchGeneration == expectedGeneration else {
                return false
            }
            self.launchingProcess = process
            self.connectionTokenFilesByProcessID[ObjectIdentifier(process)] = connectionTokenFileURL
            do {
                try process.run()
                return true
            } catch {
                if self.launchingProcess === process {
                    self.launchingProcess = nil
                }
                if let tokenFileURL = self.connectionTokenFilesByProcessID.removeValue(
                    forKey: ObjectIdentifier(process)
                ) {
                    Self.removeConnectionTokenFile(at: tokenFileURL)
                }
                return false
            }
        }
        guard didStart else {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            Self.removeConnectionTokenFile(at: connectionTokenFileURL)
            return nil
        }

        guard collector.waitForURL(timeoutSeconds: Self.serveWebStartupTimeoutSeconds),
              let serveWebURL = collector.webUIURL else {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
            } else {
                queue.sync {
                    if self.launchingProcess === process {
                        self.launchingProcess = nil
                    }
                    if self.serveWebProcess === process {
                        self.serveWebProcess = nil
                        self.serveWebURL = nil
                    }
                    if let tokenFileURL = self.connectionTokenFilesByProcessID.removeValue(
                        forKey: ObjectIdentifier(process)
                    ) {
                        Self.removeConnectionTokenFile(at: tokenFileURL)
                    }
                }
            }
            return nil
        }

        return (process, serveWebURL)
    }

    private static func drainAvailableOutput(from fileHandle: FileHandle, collector: ServeWebOutputCollector) {
        while true {
            let data = fileHandle.availableData
            guard !data.isEmpty else { return }
            collector.append(data)
        }
    }

    private static func randomConnectionToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    private static func makeConnectionTokenFile() -> URL? {
        let token = randomConnectionToken()
        let tokenFileName = "cmux-vscode-token-\(UUID().uuidString)"
        let tokenFileURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(tokenFileName, isDirectory: false)
        guard let tokenData = token.data(using: .utf8) else { return nil }

        let fileDescriptor = open(tokenFileURL.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else { return nil }
        defer { _ = close(fileDescriptor) }

        let wroteAllBytes = tokenData.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            return write(fileDescriptor, baseAddress, rawBuffer.count) == rawBuffer.count
        }
        guard wroteAllBytes else {
            removeConnectionTokenFile(at: tokenFileURL)
            return nil
        }

        return tokenFileURL
    }

    private static func removeConnectionTokenFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

final class ServeWebOutputCollector {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var outputBuffer = ""
    private var resolvedURL: URL?
    private var didSignal = false

    var webUIURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return resolvedURL
    }

    func append(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard resolvedURL == nil else { return }
        outputBuffer.append(text)
        while let newlineIndex = outputBuffer.firstIndex(where: \.isNewline) {
            let line = String(outputBuffer[..<newlineIndex])
            outputBuffer.removeSubrange(...newlineIndex)
            guard let parsedURL = VSCodeServeWebURLBuilder.extractWebUIURL(from: line) else {
                continue
            }
            resolvedURL = parsedURL
            outputBuffer.removeAll(keepingCapacity: false)
            if !didSignal {
                didSignal = true
                semaphore.signal()
            }
            return
        }
    }

    func markProcessExited() {
        lock.lock()
        defer { lock.unlock() }
        if resolvedURL == nil, !outputBuffer.isEmpty,
           let parsedURL = VSCodeServeWebURLBuilder.extractWebUIURL(from: outputBuffer) {
            resolvedURL = parsedURL
            outputBuffer.removeAll(keepingCapacity: false)
        }
        guard !didSignal else { return }
        didSignal = true
        semaphore.signal()
    }

    func waitForURL(timeoutSeconds: TimeInterval) -> Bool {
        if webUIURL != nil { return true }
        _ = semaphore.wait(timeout: .now() + timeoutSeconds)
        return webUIURL != nil
    }
}

enum WorkspaceShortcutMapper {
    /// Maps numbered workspace shortcuts to a zero-based workspace index.
    /// 1...8 target fixed indices; 9 always targets the last workspace.
    static func workspaceIndex(forDigit digit: Int, workspaceCount: Int) -> Int? {
        guard workspaceCount > 0 else { return nil }
        guard (1...9).contains(digit) else { return nil }

        if digit == 9 {
            return workspaceCount - 1
        }

        let index = digit - 1
        return index < workspaceCount ? index : nil
    }

    /// Returns the primary digit badge to display for a workspace row.
    /// Picks the lowest digit that maps to that row index.
    static func digitForWorkspace(at index: Int, workspaceCount: Int) -> Int? {
        guard index >= 0 && index < workspaceCount else { return nil }
        for digit in 1...9 {
            if workspaceIndex(forDigit: digit, workspaceCount: workspaceCount) == index {
                return digit
            }
        }
        return nil
    }
}

struct CmuxCLIPathInstaller {
    struct InstallOutcome {
        let usedAdministratorPrivileges: Bool
        let destinationURL: URL
        let sourceURL: URL
    }

    struct UninstallOutcome {
        let usedAdministratorPrivileges: Bool
        let destinationURL: URL
        let removedExistingEntry: Bool
    }

    enum InstallerError: LocalizedError {
        case bundledCLIMissing(expectedPath: String)
        case destinationParentNotDirectory(path: String)
        case destinationIsDirectory(path: String)
        case installVerificationFailed(path: String)
        case uninstallVerificationFailed(path: String)
        case privilegedCommandFailed(message: String)

        var errorDescription: String? {
            switch self {
            case .bundledCLIMissing(let expectedPath):
                return "Bundled cmux CLI was not found at \(expectedPath)."
            case .destinationParentNotDirectory(let path):
                return "Expected \(path) to be a directory."
            case .destinationIsDirectory(let path):
                return "\(path) is a directory. Remove or rename it and try again."
            case .installVerificationFailed(let path):
                return "Installed symlink at \(path) did not point to the bundled cmux CLI."
            case .uninstallVerificationFailed(let path):
                return "Failed to remove \(path)."
            case .privilegedCommandFailed(let message):
                return "Administrator action failed: \(message)"
            }
        }
    }

    typealias PrivilegedInstallHandler = (_ sourceURL: URL, _ destinationURL: URL) throws -> Void
    typealias PrivilegedUninstallHandler = (_ destinationURL: URL) throws -> Void

    let fileManager: FileManager
    let destinationURL: URL
    private let bundledCLIURLProvider: () -> URL?
    private let expectedBundledCLIPath: String
    private let privilegedInstaller: PrivilegedInstallHandler
    private let privilegedUninstaller: PrivilegedUninstallHandler

    init(
        fileManager: FileManager = .default,
        destinationURL: URL = URL(fileURLWithPath: "/usr/local/bin/cmux"),
        bundledCLIURLProvider: @escaping () -> URL? = {
            CmuxCLIPathInstaller.defaultBundledCLIURL()
        },
        expectedBundledCLIPath: String = CmuxCLIPathInstaller.defaultBundledCLIExpectedPath(),
        privilegedInstaller: PrivilegedInstallHandler? = nil,
        privilegedUninstaller: PrivilegedUninstallHandler? = nil
    ) {
        self.fileManager = fileManager
        self.destinationURL = destinationURL
        self.bundledCLIURLProvider = bundledCLIURLProvider
        self.expectedBundledCLIPath = expectedBundledCLIPath
        self.privilegedInstaller = privilegedInstaller ?? Self.installWithAdministratorPrivileges(sourceURL:destinationURL:)
        self.privilegedUninstaller = privilegedUninstaller ?? Self.uninstallWithAdministratorPrivileges(destinationURL:)
    }

    var destinationPath: String {
        destinationURL.path
    }

    func install() throws -> InstallOutcome {
        let sourceURL = try resolveBundledCLIURL()
        do {
            try installWithoutAdministratorPrivileges(sourceURL: sourceURL)
            return InstallOutcome(
                usedAdministratorPrivileges: false,
                destinationURL: destinationURL,
                sourceURL: sourceURL
            )
        } catch {
            guard Self.isPermissionDenied(error) else { throw error }
            try ensureDestinationIsNotDirectory()
            try privilegedInstaller(sourceURL, destinationURL)
            try verifyInstalledSymlinkTarget(sourceURL: sourceURL)
            return InstallOutcome(
                usedAdministratorPrivileges: true,
                destinationURL: destinationURL,
                sourceURL: sourceURL
            )
        }
    }

    func uninstall() throws -> UninstallOutcome {
        do {
            let removedExistingEntry = try uninstallWithoutAdministratorPrivileges()
            return UninstallOutcome(
                usedAdministratorPrivileges: false,
                destinationURL: destinationURL,
                removedExistingEntry: removedExistingEntry
            )
        } catch {
            guard Self.isPermissionDenied(error) else { throw error }
            try ensureDestinationIsNotDirectory()
            let removedExistingEntry = destinationEntryExists()
            try privilegedUninstaller(destinationURL)
            if destinationEntryExists() {
                throw InstallerError.uninstallVerificationFailed(path: destinationURL.path)
            }
            return UninstallOutcome(
                usedAdministratorPrivileges: true,
                destinationURL: destinationURL,
                removedExistingEntry: removedExistingEntry
            )
        }
    }

    func isInstalled() -> Bool {
        guard let sourceURL = bundledCLIURLProvider()?.standardizedFileURL else { return false }
        guard let installedTargetURL = symlinkDestinationURL() else { return false }
        return installedTargetURL == sourceURL
    }

    private func resolveBundledCLIURL() throws -> URL {
        guard let sourceURL = bundledCLIURLProvider()?.standardizedFileURL else {
            throw InstallerError.bundledCLIMissing(expectedPath: expectedBundledCLIPath)
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw InstallerError.bundledCLIMissing(expectedPath: sourceURL.path)
        }
        return sourceURL
    }

    private func installWithoutAdministratorPrivileges(sourceURL: URL) throws {
        try ensureDestinationParentDirectoryExists()
        try ensureDestinationIsNotDirectory()
        if destinationEntryExists() {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.createSymbolicLink(at: destinationURL, withDestinationURL: sourceURL)
        try verifyInstalledSymlinkTarget(sourceURL: sourceURL)
    }

    @discardableResult
    private func uninstallWithoutAdministratorPrivileges() throws -> Bool {
        try ensureDestinationIsNotDirectory()
        let existed = destinationEntryExists()
        if existed {
            try fileManager.removeItem(at: destinationURL)
        }
        if destinationEntryExists() {
            throw InstallerError.uninstallVerificationFailed(path: destinationURL.path)
        }
        return existed
    }

    /// Check if the destination path has any filesystem entry (including dangling symlinks).
    /// `FileManager.fileExists` follows symlinks, so a dangling symlink returns false.
    private func destinationEntryExists() -> Bool {
        (try? fileManager.attributesOfItem(atPath: destinationURL.path)) != nil
    }

    private func verifyInstalledSymlinkTarget(sourceURL: URL) throws {
        guard let installedTargetURL = symlinkDestinationURL(),
              installedTargetURL == sourceURL.standardizedFileURL else {
            throw InstallerError.installVerificationFailed(path: destinationURL.path)
        }
    }

    private func symlinkDestinationURL() -> URL? {
        guard fileManager.fileExists(atPath: destinationURL.path) else { return nil }
        guard let destinationPath = try? fileManager.destinationOfSymbolicLink(atPath: destinationURL.path) else {
            return nil
        }
        return URL(
            fileURLWithPath: destinationPath,
            relativeTo: destinationURL.deletingLastPathComponent()
        ).standardizedFileURL
    }

    private func ensureDestinationParentDirectoryExists() throws {
        let parentURL = destinationURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: parentURL.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw InstallerError.destinationParentNotDirectory(path: parentURL.path)
            }
            return
        }
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
    }

    private func ensureDestinationIsNotDirectory() throws {
        guard let values = try resourceValuesIfFileExists(
            at: destinationURL,
            keys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else {
            return
        }

        if values.isDirectory == true, values.isSymbolicLink != true {
            throw InstallerError.destinationIsDirectory(path: destinationURL.path)
        }
    }

    private func resourceValuesIfFileExists(
        at url: URL,
        keys: Set<URLResourceKey>
    ) throws -> URLResourceValues? {
        do {
            return try url.resourceValues(forKeys: keys)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError {
                return nil
            }
            if nsError.domain == NSPOSIXErrorDomain,
               POSIXErrorCode(rawValue: Int32(nsError.code)) == .ENOENT {
                return nil
            }
            throw error
        }
    }

    private static func defaultBundledCLIURL(bundle: Bundle = .main) -> URL? {
        bundle.resourceURL?.appendingPathComponent("bin/cmux", isDirectory: false)
    }

    private static func defaultBundledCLIExpectedPath(bundle: Bundle = .main) -> String {
        bundle.bundleURL
            .appendingPathComponent("Contents/Resources/bin/cmux", isDirectory: false)
            .path
    }

    private static func installWithAdministratorPrivileges(sourceURL: URL, destinationURL: URL) throws {
        let destinationPath = destinationURL.path
        let parentPath = destinationURL.deletingLastPathComponent().path
        let command = "/bin/mkdir -p \(shellQuoted(parentPath)) && " +
            "/bin/rm -f \(shellQuoted(destinationPath)) && " +
            "/bin/ln -s \(shellQuoted(sourceURL.path)) \(shellQuoted(destinationPath))"
        try runPrivilegedShellCommand(command)
    }

    private static func uninstallWithAdministratorPrivileges(destinationURL: URL) throws {
        let command = "/bin/rm -f \(shellQuoted(destinationURL.path))"
        try runPrivilegedShellCommand(command)
    }

    private static func runPrivilegedShellCommand(_ command: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "on run argv",
            "-e", "do shell script (item 1 of argv) with administrator privileges",
            "-e", "end run",
            command
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderrText = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stdoutText = String(
                data: stdout.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let details = stderrText.isEmpty ? stdoutText : stderrText
            let message = details.isEmpty
                ? "osascript exited with status \(process.terminationStatus)."
                : details
            throw InstallerError.privilegedCommandFailed(message: message)
        }
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func isPermissionDenied(_ error: Error) -> Bool {
        isPermissionDenied(error as NSError)
    }

    private static func isPermissionDenied(_ error: NSError) -> Bool {
        if error.domain == NSPOSIXErrorDomain,
           let code = POSIXErrorCode(rawValue: Int32(error.code)),
           code == .EACCES || code == .EPERM || code == .EROFS {
            return true
        }

        if error.domain == NSCocoaErrorDomain {
            switch error.code {
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError, NSFileWriteVolumeReadOnlyError:
                return true
            default:
                break
            }
        }

        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isPermissionDenied(underlying)
        }

        return false
    }
}

private extension NSScreen {
    var cmuxDisplayID: UInt32? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let value = deviceDescription[key] as? NSNumber else { return nil }
        return value.uint32Value
    }
}

func browserOmnibarSelectionDeltaForCommandNavigation(
    hasFocusedAddressBar: Bool,
    flags: NSEvent.ModifierFlags,
    chars: String
) -> Int? {
    guard hasFocusedAddressBar else { return nil }
    let normalizedFlags = browserOmnibarNormalizedModifierFlags(flags)
    let isCommandOrControlOnly = normalizedFlags == [.command] || normalizedFlags == [.control]
    guard isCommandOrControlOnly else { return nil }
    if chars == "n" { return 1 }
    if chars == "p" { return -1 }
    return nil
}

func browserOmnibarSelectionDeltaForArrowNavigation(
    hasFocusedAddressBar: Bool,
    flags: NSEvent.ModifierFlags,
    keyCode: UInt16
) -> Int? {
    guard hasFocusedAddressBar else { return nil }
    let normalizedFlags = browserOmnibarNormalizedModifierFlags(flags)
    guard normalizedFlags == [] else { return nil }
    switch keyCode {
    case 125: return 1
    case 126: return -1
    default: return nil
    }
}

func browserOmnibarNormalizedModifierFlags(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
    flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function, .capsLock])
}

func browserOmnibarShouldSubmitOnReturn(flags: NSEvent.ModifierFlags) -> Bool {
    let normalizedFlags = browserOmnibarNormalizedModifierFlags(flags)
    return normalizedFlags == [] || normalizedFlags == [.shift]
}

func browserResponderHasMarkedText(_ responder: NSResponder?) -> Bool {
    guard let responder else { return false }

    // During IME composition, Return/Enter belongs to the text system so the
    // candidate list can commit or confirm the marked text.
    if let textInputClient = responder as? NSTextInputClient {
        return textInputClient.hasMarkedText()
    }

    if let textField = responder as? NSTextField,
       let editor = textField.currentEditor() as? NSTextView {
        return editor.hasMarkedText()
    }

    return false
}

func shouldDispatchBrowserReturnViaFirstResponderKeyDown(
    keyCode: UInt16,
    firstResponderIsBrowser: Bool,
    firstResponderHasMarkedText: Bool = false,
    flags: NSEvent.ModifierFlags
) -> Bool {
    guard firstResponderIsBrowser else { return false }
    guard !firstResponderHasMarkedText else { return false }
    guard keyCode == 36 || keyCode == 76 else { return false }
    // Keep browser Return forwarding narrow: only plain/Shift Return should be
    // treated as submit-intent. Command-modified Return is reserved for app shortcuts
    // like Toggle Pane Zoom (Cmd+Shift+Enter).
    return browserOmnibarShouldSubmitOnReturn(flags: flags)
}

func shouldDispatchBrowserArrowViaFirstResponderKeyDown(
    keyCode: UInt16,
    firstResponderIsBrowser: Bool,
    firstResponderHasMarkedText: Bool = false,
    flags: NSEvent.ModifierFlags
) -> Bool {
    guard firstResponderIsBrowser else { return false }
    guard !firstResponderHasMarkedText else { return false }
    guard keyCode == 125 || keyCode == 126 else { return false }

    // Keep this narrow to avoid stealing app/browser shortcuts that layer onto
    // modified arrow keys. Plain up/down should always flow through keyDown so
    // web content such as Google Docs receives the event directly.
    let normalizedFlags = flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function, .capsLock])
    return normalizedFlags.isEmpty
}

func shouldToggleMainWindowFullScreenForCommandControlFShortcut(
    flags: NSEvent.ModifierFlags,
    chars: String,
    keyCode: UInt16,
    layoutCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? = KeyboardLayout.character(forKeyCode:modifierFlags:)
) -> Bool {
    let normalizedFlags = flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function, .capsLock])
    guard normalizedFlags == [.command, .control] else { return false }
    let normalizedChars = chars.lowercased()
    if normalizedChars == "f" {
        return true
    }
    let charsAreControlSequence = !normalizedChars.isEmpty
        && normalizedChars.unicodeScalars.allSatisfy { CharacterSet.controlCharacters.contains($0) }
    if !normalizedChars.isEmpty && !charsAreControlSequence {
        return false
    }

    // Fallback to layout translation only when characters are unavailable (for
    // synthetic/key-equivalent paths that can report an empty string).
    if let translatedCharacter = layoutCharacterProvider(keyCode, flags), !translatedCharacter.isEmpty {
        return translatedCharacter == "f"
    }

    // Keep ANSI fallback as a final safety net when layout translation is unavailable.
    return keyCode == 3
}

func commandPaletteSelectionDeltaForKeyboardNavigation(
    flags: NSEvent.ModifierFlags,
    chars: String,
    keyCode: UInt16
) -> Int? {
    let normalizedFlags = flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function])
    let normalizedChars = chars.lowercased()

    if normalizedFlags == [] {
        switch keyCode {
        case 125: return 1    // Down arrow
        case 126: return -1   // Up arrow
        default: break
        }
    }

    if normalizedFlags == [.control] {
        // Control modifiers can surface as either printable chars or ASCII control chars.
        // Keep Emacs-style next/previous navigation, but leave other control bindings
        // (for example Ctrl+K text editing in the palette search field) to AppKit.
        if keyCode == 45 || normalizedChars == "n" || normalizedChars == "\u{0e}" { return 1 }    // Ctrl+N
        if keyCode == 35 || normalizedChars == "p" || normalizedChars == "\u{10}" { return -1 }   // Ctrl+P
    }

    return nil
}

func shouldRouteCommandPaletteSelectionNavigation(
    delta: Int?,
    isInteractive: Bool,
    usesInlineTextHandling: Bool
) -> Bool {
    guard delta != nil, isInteractive else { return false }
    return !usesInlineTextHandling
}

func shouldConsumeShortcutWhileCommandPaletteVisible(
    isCommandPaletteVisible: Bool,
    normalizedFlags: NSEvent.ModifierFlags,
    chars: String,
    keyCode: UInt16
) -> Bool {
    guard isCommandPaletteVisible else { return false }

    // Escape dismisses the palette, and must not leak through to the
    // underlying terminal or browser content.
    if normalizedFlags.isEmpty, keyCode == 53 {
        return true
    }

    guard normalizedFlags.contains(.command) else { return false }

    let normalizedChars = chars.lowercased()

    if normalizedFlags == [.command] {
        if normalizedChars == "a"
            || normalizedChars == "c"
            || normalizedChars == "v"
            || normalizedChars == "x"
            || normalizedChars == "z"
            || normalizedChars == "y" {
            return false
        }

        switch keyCode {
        case 51, 117, 123, 124:
            return false
        default:
            break
        }
    }

    if normalizedFlags == [.command, .shift], normalizedChars == "z" {
        return false
    }

    return true
}

func shouldSubmitCommandPaletteWithReturn(
    keyCode: UInt16,
    flags: NSEvent.ModifierFlags,
    mode: String
) -> Bool {
    guard keyCode == 36 || keyCode == 76 else { return false }
    let normalizedFlags = flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function, .capsLock])
    if normalizedFlags.isEmpty {
        return true
    }
    if normalizedFlags == [.shift] {
        return mode != "workspace_description_input"
    }
    return false
}

func commandPaletteFieldEditorHasMarkedText(in window: NSWindow) -> Bool {
    if let editor = window.firstResponder as? NSTextView {
        return editor.hasMarkedText()
    }
    if let textField = window.firstResponder as? NSTextField,
       let editor = textField.currentEditor() as? NSTextView {
        return editor.hasMarkedText()
    }
    return false
}

func shouldHandleCommandPaletteShortcutEvent(
    _ event: NSEvent,
    paletteWindow: NSWindow?
) -> Bool {
    guard let paletteWindow else { return false }
    if let eventWindow = event.window {
        return eventWindow === paletteWindow
    }
    let eventWindowNumber = event.windowNumber
    if eventWindowNumber > 0 {
        return eventWindowNumber == paletteWindow.windowNumber
    }
    if let keyWindow = NSApp.keyWindow {
        return keyWindow === paletteWindow
    }
    return false
}

enum BrowserZoomShortcutAction: Equatable {
    case zoomIn
    case zoomOut
    case reset
}

struct CommandPaletteDebugResultRow {
    let commandId: String
    let title: String
    let shortcutHint: String?
    let trailingLabel: String?
    let score: Int
}

struct CommandPaletteDebugSnapshot {
    let query: String
    let mode: String
    let results: [CommandPaletteDebugResultRow]

    static let empty = CommandPaletteDebugSnapshot(query: "", mode: "commands", results: [])
}

func browserZoomShortcutAction(
    flags: NSEvent.ModifierFlags,
    chars: String,
    keyCode: UInt16,
    literalChars: String? = nil
) -> BrowserZoomShortcutAction? {
    let normalizedFlags = flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function])
    let hasCommand = normalizedFlags.contains(.command)
    let hasOnlyCommandAndOptionalShift = hasCommand && normalizedFlags.isDisjoint(with: [.control, .option])

    guard hasOnlyCommandAndOptionalShift else { return nil }
    let keys = browserZoomShortcutKeyCandidates(
        chars: chars,
        literalChars: literalChars,
        keyCode: keyCode
    )

    if keys.contains("=") || keys.contains("+") || keyCode == 24 || keyCode == 69 { // kVK_ANSI_Equal / kVK_ANSI_KeypadPlus
        return .zoomIn
    }

    if keys.contains("-") || keys.contains("_") || keyCode == 27 || keyCode == 78 { // kVK_ANSI_Minus / kVK_ANSI_KeypadMinus
        return .zoomOut
    }

    if keys.contains("0") || keyCode == 29 || keyCode == 82 { // kVK_ANSI_0 / kVK_ANSI_Keypad0
        return .reset
    }

    return nil
}

func browserZoomShortcutKeyCandidates(
    chars: String,
    literalChars: String?,
    keyCode: UInt16
) -> Set<String> {
    var keys: Set<String> = [chars.lowercased()]

    if let literalChars, !literalChars.isEmpty {
        keys.insert(literalChars.lowercased())
    }

    if let layoutChar = KeyboardLayout.character(forKeyCode: keyCode), !layoutChar.isEmpty {
        keys.insert(layoutChar)
    }

    return keys
}

func shouldSuppressSplitShortcutForTransientTerminalFocusInputs(
    firstResponderIsWindow: Bool,
    hostedSize: CGSize,
    hostedHiddenInHierarchy: Bool,
    hostedAttachedToWindow: Bool
) -> Bool {
    guard firstResponderIsWindow else { return false }
    let tinyGeometry = hostedSize.width <= 1 || hostedSize.height <= 1
    return tinyGeometry || hostedHiddenInHierarchy || !hostedAttachedToWindow
}

func shouldRouteTerminalFontZoomShortcutToGhostty(
    firstResponderIsGhostty: Bool,
    flags: NSEvent.ModifierFlags,
    chars: String,
    keyCode: UInt16,
    literalChars: String? = nil
) -> Bool {
    guard firstResponderIsGhostty else { return false }
    return browserZoomShortcutAction(
        flags: flags,
        chars: chars,
        keyCode: keyCode,
        literalChars: literalChars
    ) != nil
}

@discardableResult
func startOrFocusTerminalSearch(
    _ terminalSurface: TerminalSurface,
    searchFocusNotifier: @escaping (TerminalSurface) -> Void = {
        NotificationCenter.default.post(name: .ghosttySearchFocus, object: $0)
    }
) -> Bool {
    if terminalSurface.searchState != nil {
        searchFocusNotifier(terminalSurface)
        return true
    }

    if terminalSurface.performBindingAction("start_search") {
        DispatchQueue.main.async { [weak terminalSurface] in
            guard let terminalSurface, terminalSurface.searchState == nil else { return }
            terminalSurface.searchState = TerminalSurface.SearchState()
            searchFocusNotifier(terminalSurface)
        }
        return true
    }

    terminalSurface.searchState = TerminalSurface.SearchState()
    searchFocusNotifier(terminalSurface)
    return true
}

/// Let AppKit own native Cmd+` window cycling so key-window changes do not
/// re-enter our direct-to-menu shortcut path.
func shouldRouteCommandEquivalentDirectlyToMainMenu(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard flags.contains(.command) else { return false }

    let normalizedFlags = flags.subtracting([.numericPad, .function, .capsLock])
    if event.keyCode == 50,
       normalizedFlags == [.command] || normalizedFlags == [.command, .shift] {
        return false
    }

    return true
}

private enum BrowserFindCommandEquivalent {
    case find
    case findNext
    case findPrevious
    case hideFind
    case useSelection

    var keepsCmuxBrowserFindBarOwnershipWhenVisible: Bool {
        switch self {
        case .find, .findNext, .findPrevious, .hideFind:
            return true
        case .useSelection:
            return false
        }
    }
}

private func cmuxIsLikelyWebInspectorResponder(_ responder: NSResponder?) -> Bool {
    guard let responder else { return false }
    let responderType = String(describing: type(of: responder))
    if responderType.contains("WKInspector") {
        return true
    }
    guard let view = responder as? NSView else { return false }
    var node: NSView? = view
    var hops = 0
    while let current = node, hops < 64 {
        if String(describing: type(of: current)).contains("WKInspector") {
            return true
        }
        node = current.superview
        hops += 1
    }
    return false
}

private func browserFindCommandEquivalent(for event: NSEvent) -> BrowserFindCommandEquivalent? {
    let flags = event.modifierFlags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function, .capsLock])

    let normalizedChars = KeyboardLayout.normalizedCharacters(for: event).lowercased()
    let hasSingleASCIIShortcutChar =
        normalizedChars.count == 1 && normalizedChars.allSatisfy(\.isASCII)
    let producedAnyASCIIShortcutChar = normalizedChars.contains(where: \.isASCII)
    func matches(_ chars: String, keyCode: UInt16) -> Bool {
        if hasSingleASCIIShortcutChar {
            return normalizedChars == chars
        }
        if !producedAnyASCIIShortcutChar {
            return event.keyCode == keyCode
        }
        return false
    }

    switch flags {
    case [.command]:
        if matches("e", keyCode: 14) { // kVK_ANSI_E
            return .useSelection
        }
        if matches("f", keyCode: 3) { // kVK_ANSI_F
            return .find
        }
        if matches("g", keyCode: 5) { // kVK_ANSI_G
            return .findNext
        }
        return nil
    case [.command, .shift]:
        if matches("f", keyCode: 3) { // kVK_ANSI_F
            return .hideFind
        }
        if matches("g", keyCode: 5) { // kVK_ANSI_G
            return .findPrevious
        }
        return nil
    default:
        return nil
    }
}

/// For browser content, let the page try the Find command family before cmux's menu fallback.
/// This preserves native web-app shortcuts like VS Code's Cmd+F while still allowing cmux's
/// browser find overlay to keep owning its visible Find UI shortcuts.
func shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst(
    _ event: NSEvent,
    responder: NSResponder? = nil,
    owningWebView: CmuxWebView? = nil
) -> Bool {
    guard let shortcut = browserFindCommandEquivalent(for: event) else {
        return false
    }

    if cmuxIsLikelyWebInspectorResponder(responder) {
        return false
    }

    if shortcut.keepsCmuxBrowserFindBarOwnershipWhenVisible,
       let owningWebView {
        let browserFindBarIsVisible = MainActor.assumeIsolated {
            AppDelegate.shared?.browserFindBarIsVisible(for: owningWebView) == true
        }
        if browserFindBarIsVisible {
            return false
        }
    }

    return true
}

func cmuxOwningGhosttyView(for responder: NSResponder?) -> GhosttyNSView? {
    guard let responder else { return nil }
    if let ghosttyView = responder as? GhosttyNSView {
        return ghosttyView
    }

    if let view = responder as? NSView,
       let ghosttyView = cmuxOwningGhosttyView(for: view) {
        return ghosttyView
    }

    if let textView = responder as? NSTextView {
        if textView.isFieldEditor,
           let ownerView = cmuxFieldEditorOwnerView(textView),
           let ghosttyView = cmuxOwningGhosttyView(for: ownerView) {
            return ghosttyView
        }

        if !textView.isFieldEditor,
           let delegateView = textView.delegate as? NSView,
           let ghosttyView = cmuxOwningGhosttyView(for: delegateView) {
            return ghosttyView
        }
    }

    var current = responder.nextResponder
    while let next = current {
        if let ghosttyView = next as? GhosttyNSView {
            return ghosttyView
        }
        if let view = next as? NSView,
           let ghosttyView = cmuxOwningGhosttyView(for: view) {
            return ghosttyView
        }
        current = next.nextResponder
    }

    return nil
}

private func cmuxFieldEditorOwnerView(_ editor: NSTextView) -> NSView? {
    guard editor.isFieldEditor else { return nil }

    var current = editor.nextResponder
    while let next = current {
        if let view = next as? NSView {
            return view
        }
        current = next.nextResponder
    }

    return editor.superview
}

private func cmuxOwningGhosttyView(for view: NSView) -> GhosttyNSView? {
    if let ghosttyView = view as? GhosttyNSView {
        return ghosttyView
    }

    var current: NSView? = view.superview
    while let candidate = current {
        if let ghosttyView = candidate as? GhosttyNSView {
            return ghosttyView
        }
        current = candidate.superview
    }

    return nil
}

#if DEBUG
func browserZoomShortcutTraceCandidate(
    flags: NSEvent.ModifierFlags,
    chars: String,
    keyCode: UInt16,
    literalChars: String? = nil
) -> Bool {
    let normalizedFlags = flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function])
    guard normalizedFlags.contains(.command) else { return false }

    let keys = browserZoomShortcutKeyCandidates(
        chars: chars,
        literalChars: literalChars,
        keyCode: keyCode
    )
    if keys.contains("=") || keys.contains("+") || keys.contains("-") || keys.contains("_") || keys.contains("0") {
        return true
    }
    switch keyCode {
    case 24, 27, 29, 69, 78, 82: // ANSI and keypad zoom keys
        return true
    default:
        return false
    }
}

func browserZoomShortcutTraceFlagsString(_ flags: NSEvent.ModifierFlags) -> String {
    let normalizedFlags = flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function])
    var parts: [String] = []
    if normalizedFlags.contains(.command) { parts.append("Cmd") }
    if normalizedFlags.contains(.shift) { parts.append("Shift") }
    if normalizedFlags.contains(.option) { parts.append("Opt") }
    if normalizedFlags.contains(.control) { parts.append("Ctrl") }
    return parts.isEmpty ? "none" : parts.joined(separator: "+")
}

func browserZoomShortcutTraceActionString(_ action: BrowserZoomShortcutAction?) -> String {
    guard let action else { return "none" }
    switch action {
    case .zoomIn: return "zoomIn"
    case .zoomOut: return "zoomOut"
    case .reset: return "reset"
    }
}
#endif

func shouldSuppressWindowMoveForFolderDrag(hitView: NSView?) -> Bool {
    var candidate = hitView
    while let view = candidate {
        if view is DraggableFolderNSView {
            return true
        }
        candidate = view.superview
    }
    return false
}

func shouldSuppressWindowMoveForFolderDrag(window: NSWindow, event: NSEvent) -> Bool {
    guard event.type == .leftMouseDown,
          window.isMovable,
          let contentView = window.contentView else {
        return false
    }

    let contentPoint = contentView.convert(event.locationInWindow, from: nil)
    let hitView = contentView.hitTest(contentPoint)
    return shouldSuppressWindowMoveForFolderDrag(hitView: hitView)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSMenuItemValidation {
    nonisolated(unsafe) static var shared: AppDelegate?

    private static let cachedIsRunningUnderXCTest = detectRunningUnderXCTest(ProcessInfo.processInfo.environment)

    private var isRunningUnderXCTestCached: Bool {
        Self.cachedIsRunningUnderXCTest
    }

    private static func detectRunningUnderXCTest(_ env: [String: String]) -> Bool {
        if env["XCTestConfigurationFilePath"] != nil { return true }
        if env["XCTestBundlePath"] != nil { return true }
        if env["XCTestSessionIdentifier"] != nil { return true }
        if env["XCInjectBundle"] != nil { return true }
        if env["XCInjectBundleInto"] != nil { return true }
        if env["DYLD_INSERT_LIBRARIES"]?.contains("libXCTest") == true { return true }
        if env.keys.contains(where: { $0.hasPrefix("CMUX_UI_TEST_") }) { return true }
        return false
    }

    private func isRunningUnderXCTest(_ env: [String: String]) -> Bool {
        // On some macOS/Xcode setups, the app-under-test process doesn't get
        // `XCTestConfigurationFilePath`. Use a broader set of signals so UI tests
        // can reliably skip heavyweight startup work and bring up a window.
        Self.detectRunningUnderXCTest(env)
    }

    private final class MainWindowContext {
        let windowId: UUID
        let tabManager: TabManager
        let sidebarState: SidebarState
        let sidebarSelectionState: SidebarSelectionState
        weak var window: NSWindow?

        init(
            windowId: UUID,
            tabManager: TabManager,
            sidebarState: SidebarState,
            sidebarSelectionState: SidebarSelectionState,
            window: NSWindow?
        ) {
            self.windowId = windowId
            self.tabManager = tabManager
            self.sidebarState = sidebarState
            self.sidebarSelectionState = sidebarSelectionState
            self.window = window
        }
    }

    private final class MainWindowController: NSWindowController, NSWindowDelegate {
        var onClose: (() -> Void)?

        func windowWillClose(_ notification: Notification) {
            onClose?()
        }
    }

    struct ScriptableMainWindowState {
        let windowId: UUID
        let tabManager: TabManager
        let window: NSWindow?
    }

    struct SessionDisplayGeometry {
        let displayID: UInt32?
        let frame: CGRect
        let visibleFrame: CGRect
    }

    struct PersistedWindowGeometry: Codable, Sendable {
        let version: Int
        let frame: SessionRectSnapshot
        let display: SessionDisplaySnapshot?
    }

    nonisolated static let persistedWindowGeometrySchemaVersion = 2
    private nonisolated static let persistedWindowGeometryDefaultsKey = "cmux.session.lastWindowGeometry.v2"
    private nonisolated static let legacyPersistedWindowGeometryDefaultsKeys = [
        "cmux.session.lastWindowGeometry.v1"
    ]

    weak var tabManager: TabManager?
    weak var notificationStore: TerminalNotificationStore?
    weak var sidebarState: SidebarState?
    weak var fullscreenControlsViewModel: TitlebarControlsViewModel?
    weak var sidebarSelectionState: SidebarSelectionState?
    var shortcutLayoutCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? = KeyboardLayout.character(forKeyCode:modifierFlags:)
    private var workspaceObserver: NSObjectProtocol?
    private var lifecycleSnapshotObservers: [NSObjectProtocol] = []
    private var windowKeyObserver: NSObjectProtocol?
    private var shortcutMonitor: Any?
    private var shortcutDefaultsObserver: NSObjectProtocol?
    private var menuBarVisibilityObserver: NSObjectProtocol?
    private var splitButtonTooltipRefreshScheduled = false
    private struct PendingConfiguredShortcutChord {
        let firstStroke: ShortcutStroke
        let windowNumber: Int?
    }
    private var pendingConfiguredShortcutChord: PendingConfiguredShortcutChord?
    private var activeConfiguredShortcutChordPrefixForCurrentEvent: ShortcutStroke?
    private var configuredShortcutChordActions: [KeyboardShortcutSettings.Action] = []
    private var ghosttyConfigObserver: NSObjectProtocol?
    private var ghosttyGotoSplitLeftShortcut: StoredShortcut?
    private var ghosttyGotoSplitRightShortcut: StoredShortcut?
    private var ghosttyGotoSplitUpShortcut: StoredShortcut?
    private var ghosttyGotoSplitDownShortcut: StoredShortcut?
    private var browserAddressBarFocusedPanelId: UUID?
    private var browserOmnibarRepeatStartWorkItem: DispatchWorkItem?
    private var browserOmnibarRepeatTickWorkItem: DispatchWorkItem?
    private var browserOmnibarRepeatKeyCode: UInt16?
    private var browserOmnibarRepeatDelta: Int = 0
    private var browserAddressBarFocusObserver: NSObjectProtocol?
    private var browserAddressBarBlurObserver: NSObjectProtocol?
    private var browserWebViewFirstResponderObserver: NSObjectProtocol?
    private let updateController = UpdateController()
    private lazy var titlebarAccessoryController = UpdateTitlebarAccessoryController(viewModel: updateViewModel)
    private let windowDecorationsController = WindowDecorationsController()
    private var menuBarExtraController: MenuBarExtraController?
    private static let serviceErrorNoPath = NSString(string: String(localized: "error.clipboardFolderPath", defaultValue: "Could not load any folder path from the clipboard."))
    private static let didInstallWindowKeyEquivalentSwizzle: Void = {
        let targetClass: AnyClass = NSWindow.self
        let originalSelector = #selector(NSWindow.performKeyEquivalent(with:))
        let swizzledSelector = #selector(NSWindow.cmux_performKeyEquivalent(with:))
        guard let originalMethod = class_getInstanceMethod(targetClass, originalSelector),
              let swizzledMethod = class_getInstanceMethod(targetClass, swizzledSelector) else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }()
    private static let didInstallWindowFirstResponderSwizzle: Void = {
        let targetClass: AnyClass = NSWindow.self
        let originalSelector = #selector(NSWindow.makeFirstResponder(_:))
        let swizzledSelector = #selector(NSWindow.cmux_makeFirstResponder(_:))
        guard let originalMethod = class_getInstanceMethod(targetClass, originalSelector),
              let swizzledMethod = class_getInstanceMethod(targetClass, swizzledSelector) else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }()
    private static let didInstallWindowSendEventSwizzle: Void = {
        let targetClass: AnyClass = NSWindow.self
        let originalSelector = #selector(NSWindow.sendEvent(_:))
        let swizzledSelector = #selector(NSWindow.cmux_sendEvent(_:))
        guard let originalMethod = class_getInstanceMethod(targetClass, originalSelector),
              let swizzledMethod = class_getInstanceMethod(targetClass, swizzledSelector) else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }()
    private static let didInstallApplicationSendEventSwizzle: Void = {
        let targetClass: AnyClass = NSApplication.self
        let originalSelector = #selector(NSApplication.sendEvent(_:))
        let swizzledSelector = #selector(NSApplication.cmux_applicationSendEvent(_:))
        guard let originalMethod = class_getInstanceMethod(targetClass, originalSelector),
              let swizzledMethod = class_getInstanceMethod(targetClass, swizzledSelector) else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }()

#if DEBUG
    private var didSetupJumpUnreadUITest = false
    private var jumpUnreadFocusExpectation: (tabId: UUID, surfaceId: UUID)?
    private var jumpUnreadFocusObserver: NSObjectProtocol?
    private var didSetupTerminalCmdClickUITest = false
    private var didSetupGotoSplitUITest = false
    private var didSetupBonsplitTabDragUITest = false
    private var terminalCmdClickUITestPoller: DispatchSourceTimer?
    private var bonsplitTabDragUITestRecorder: DispatchSourceTimer?
    private var gotoSplitUITestRecorder: DispatchSourceTimer?
    private var gotoSplitUITestObservers: [NSObjectProtocol] = []
    private var didSetupMultiWindowNotificationsUITest = false
    private var didSetupDisplayResolutionUITestDiagnostics = false
    private var displayResolutionUITestObservers: [NSObjectProtocol] = []
    private struct UITestRenderDiagnosticsSnapshot {
        let panelId: UUID
        let drawCount: Int
        let presentCount: Int
        let lastPresentTime: Double
        let windowVisible: Bool
        let appIsActive: Bool
        let desiredFocus: Bool
        let isFirstResponder: Bool
    }
    var debugCloseMainWindowConfirmationHandler: ((NSWindow) -> Bool)?
    var debugCreateMainWindowSourceIsNativeFullScreenOverride: Bool?
    // Keep debug-only windows alive when tests intentionally inject key mismatches.
    private var debugDetachedContextWindows: [NSWindow] = []

    private func childExitKeyboardProbePath() -> String? {
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP"] == "1",
              let path = env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_PATH"],
              !path.isEmpty else {
            return nil
        }
        return path
    }

    private func childExitKeyboardProbeHex(_ value: String?) -> String {
        guard let value else { return "" }
        return value.unicodeScalars
            .map { String(format: "%04X", $0.value) }
            .joined(separator: ",")
    }

    private func writeChildExitKeyboardProbe(_ updates: [String: String], increments: [String: Int] = [:]) {
        guard let path = childExitKeyboardProbePath() else { return }
        var payload: [String: String] = {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                return [:]
            }
            return object
        }()
        for (key, by) in increments {
            let current = Int(payload[key] ?? "") ?? 0
            payload[key] = String(current + by)
        }
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
#endif

    private var mainWindowContexts: [ObjectIdentifier: MainWindowContext] = [:]
    private var mainWindowControllers: [MainWindowController] = []

    /// Tracks the cascade point for new windows, matching Ghostty's upstream algorithm.
    /// Reset to `.zero` so the first window seeds the point from its own position.
    private var lastCascadePoint = NSPoint.zero
    private var startupSessionSnapshot: AppSessionSnapshot?
    private var didPrepareStartupSessionSnapshot = false
    private var didAttemptStartupSessionRestore = false
    private var isApplyingStartupSessionRestore = false
    private var sessionAutosaveTimer: DispatchSourceTimer?
    private var sessionAutosaveTickInFlight = false
    private var sessionAutosaveDeferredRetryPending = false
    private let sessionPersistenceQueue = DispatchQueue(
        label: "com.cmuxterm.app.sessionPersistence",
        qos: .utility
    )
    private nonisolated static let launchServicesRegistrationQueue = DispatchQueue(
        label: "com.cmuxterm.app.launchServicesRegistration",
        qos: .utility
    )
    private nonisolated static func enqueueLaunchServicesRegistrationWork(_ work: @escaping @Sendable () -> Void) {
        launchServicesRegistrationQueue.async(execute: work)
    }
    private var lastSessionAutosaveFingerprint: Int?
    private var lastSessionAutosavePersistedAt: Date = .distantPast
    private var lastTypingActivityAt: TimeInterval = 0
    private var didHandleExplicitOpenIntentAtStartup = false
    private var isTerminatingApp = false
    // Set to true when the user has already confirmed quit via the warning dialog,
    // so applicationShouldTerminate does not show a second alert.
    private var isQuitWarningConfirmed = false
    private var didInstallLifecycleSnapshotObservers = false
    private var didDisableSuddenTermination = false
    private var commandPaletteVisibilityByWindowId: [UUID: Bool] = [:]
    private var commandPalettePendingOpenByWindowId: [UUID: Bool] = [:]
    private var commandPaletteRecentRequestAtByWindowId: [UUID: TimeInterval] = [:]
    private var commandPaletteEscapeSuppressionByWindowId: Set<UUID> = []
    private var commandPaletteEscapeSuppressionStartedAtByWindowId: [UUID: TimeInterval] = [:]
    private var commandPaletteSelectionByWindowId: [UUID: Int] = [:]
    private var commandPaletteSnapshotByWindowId: [UUID: CommandPaletteDebugSnapshot] = [:]
    private static let commandPaletteRequestGraceInterval: TimeInterval = 1.25
    private static let commandPalettePendingOpenMaxAge: TimeInterval = 8.0
    private static let sessionAutosaveTypingQuietPeriod: TimeInterval = 0.65

    var updateViewModel: UpdateViewModel {
        updateController.viewModel
    }

#if DEBUG
    private func pointerString(_ object: AnyObject?) -> String {
        guard let object else { return "nil" }
        return String(describing: Unmanaged.passUnretained(object).toOpaque())
    }

    private func summarizeContextForWorkspaceRouting(_ context: MainWindowContext?) -> String {
        guard let context else { return "nil" }
        let window = context.window ?? windowForMainWindowId(context.windowId)
        let windowNumber = window?.windowNumber ?? -1
        let key = window?.isKeyWindow == true ? 1 : 0
        let main = window?.isMainWindow == true ? 1 : 0
        let visible = window?.isVisible == true ? 1 : 0
        let selected = context.tabManager.selectedTabId.map { String($0.uuidString.prefix(8)) } ?? "nil"
        return "wid=\(context.windowId.uuidString.prefix(8)) win=\(windowNumber) key=\(key) main=\(main) vis=\(visible) tabs=\(context.tabManager.tabs.count) sel=\(selected) tm=\(pointerString(context.tabManager))"
    }

    private func summarizeAllContextsForWorkspaceRouting() -> String {
        guard !mainWindowContexts.isEmpty else { return "<none>" }
        return mainWindowContexts.values
            .map { summarizeContextForWorkspaceRouting($0) }
            .joined(separator: " | ")
    }

    private func logWorkspaceCreationRouting(
        phase: String,
        source: String,
        reason: String,
        event: NSEvent?,
        chosenContext: MainWindowContext?,
        workspaceId: UUID? = nil,
        workingDirectory: String? = nil
    ) {
        let eventWindowNumber = event?.window?.windowNumber ?? -1
        let eventNumber = event?.windowNumber ?? -1
        let eventChars = event?.charactersIgnoringModifiers ?? ""
        let eventKeyCode = event.map { String($0.keyCode) } ?? "nil"
        let keyWindowNumber = NSApp.keyWindow?.windowNumber ?? -1
        let mainWindowNumber = NSApp.mainWindow?.windowNumber ?? -1
        let ws = workspaceId.map { String($0.uuidString.prefix(8)) } ?? "nil"
        let wd = workingDirectory.map { String($0.prefix(120)) } ?? "-"
        FocusLogStore.shared.append(
            "cmdn.route phase=\(phase) src=\(source) reason=\(reason) eventWin=\(eventWindowNumber) eventNum=\(eventNumber) keyCode=\(eventKeyCode) chars=\(eventChars) keyWin=\(keyWindowNumber) mainWin=\(mainWindowNumber) activeTM=\(pointerString(tabManager)) chosen={\(summarizeContextForWorkspaceRouting(chosenContext))} ws=\(ws) wd=\(wd) contexts=[\(summarizeAllContextsForWorkspaceRouting())]"
        )
    }
#endif

    override init() {
        super.init()
        Self.shared = self
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let directories = externalOpenDirectories(from: urls)
        guard !directories.isEmpty else { return }

        prepareForExplicitOpenIntentAtStartup()
        for directory in directories {
            openWorkspaceForExternalDirectory(
                workingDirectory: directory,
                debugSource: "application.openURLs"
            )
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = ProcessInfo.processInfo.environment
        let isRunningUnderXCTest = isRunningUnderXCTest(env)
        let telemetryEnabled = TelemetrySettings.enabledForCurrentLaunch

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleThemesReloadNotification(_:)),
            name: CmuxThemeNotifications.reloadConfig,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleReactGrabDidCopySelection(_:)),
            name: .reactGrabDidCopySelection,
            object: nil
        )

#if DEBUG
        // UI tests run on a shared VM user profile, so persisted shortcuts can drift and make
        // key-equivalent routing flaky. Force defaults for deterministic tests.
        if isRunningUnderXCTest {
            SystemWideHotkeySettings.reset()
            KeyboardShortcutSettings.resetAll()
        }
#endif

#if DEBUG
        writeUITestDiagnosticsIfNeeded(stage: "didFinishLaunching")
        CmuxMainRunLoopStallMonitor.shared.installIfNeeded()
        CmuxMainThreadTurnProfiler.shared.installIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.writeUITestDiagnosticsIfNeeded(stage: "after1s")
        }
#endif

        if telemetryEnabled {
            // Pre-warm locale before Sentry to avoid a startup data race.
            // Locale initialization (os.locale.ensureLocale / NSLocale._preferredLanguages)
            // on the main thread can race with Sentry's background init thread
            // calling posix.getenv, causing a SIGSEGV ~134ms after launch.
            // Forcing locale access here before SentrySDK.start eliminates the race.
            // Related to: #836
            _ = Locale.current
            _ = NSLocale.preferredLanguages

            SentrySDK.start { options in
                options.dsn = "https://ecba1ec90ecaee02a102fba931b6d2b3@o4507547940749312.ingest.us.sentry.io/4510796264636416"
                #if DEBUG
                options.environment = "development"
                options.debug = true
                #else
                options.environment = "production"
                options.debug = false
                #endif
                options.sendDefaultPii = false

                // Performance tracing (10% of transactions)
                options.tracesSampleRate = 0.1
                // Keep app-hang tracking enabled, but avoid reporting short main-thread stalls
                // as hangs in normal user interaction flows.
                options.appHangTimeoutInterval = 8.0
                // Attach stack traces to all events
                options.attachStacktrace = true
                // Avoid recursively capturing failed requests from Sentry's own ingestion endpoint.
                options.enableCaptureFailedRequests = false
            }
        }

        if telemetryEnabled && !isRunningUnderXCTest {
            PostHogAnalytics.shared.startIfNeeded()
        }

        let forceDuplicateLaunchObserver = env["CMUX_UI_TEST_ENABLE_DUPLICATE_LAUNCH_OBSERVER"] == "1"

        // UI tests frequently time out waiting for the main window if we do heavyweight
        // LaunchServices registration / single-instance enforcement synchronously at startup.
        // Skip these during XCTest (the app-under-test) so the window can appear quickly.
        if !isRunningUnderXCTest {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduleLaunchServicesBundleRegistration()
                self.enforceSingleInstance()
                self.observeDuplicateLaunches()
            }
        } else if forceDuplicateLaunchObserver {
            // Some UI regressions specifically exercise launch-observer behavior while still
            // running under XCTest. Allow an explicit opt-in for those cases only.
            DispatchQueue.main.async { [weak self] in
                self?.observeDuplicateLaunches()
            }
        }
        NSWindow.allowsAutomaticWindowTabbing = false
        disableNativeTabbingShortcut()
        ensureApplicationIcon()
        if !isRunningUnderXCTest {
            configureUserNotifications()
            installMenuBarVisibilityObserver()
            syncMenuBarExtraVisibility()
            updateController.startUpdaterIfNeeded()
        }
        titlebarAccessoryController.start()
        windowDecorationsController.start()
        installMainWindowKeyObserver()
        refreshGhosttyGotoSplitShortcuts()
        installGhosttyConfigObserver()
        installWindowResponderSwizzles()
        installBrowserAddressBarFocusObservers()
        installShortcutMonitor()
        installShortcutDefaultsObserver()
        SystemWideHotkeyController.shared.start()
        NSApp.servicesProvider = self
#if DEBUG
        UpdateTestSupport.applyIfNeeded(to: updateController.viewModel)
        if env["CMUX_UI_TEST_MODE"] == "1" {
            let trigger = env["CMUX_UI_TEST_TRIGGER_UPDATE_CHECK"] ?? "<nil>"
            let feed = env["CMUX_UI_TEST_FEED_URL"] ?? "<nil>"
            UpdateLogStore.shared.append("ui test env: trigger=\(trigger) feed=\(feed)")
        }
        if env["CMUX_UI_TEST_TRIGGER_UPDATE_CHECK"] == "1" {
            UpdateLogStore.shared.append("ui test trigger update check detected")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                let windowIds = NSApp.windows.map { $0.identifier?.rawValue ?? "<nil>" }
                UpdateLogStore.shared.append("ui test windows: count=\(NSApp.windows.count) ids=\(windowIds.joined(separator: ","))")
                if UpdateTestSupport.performMockFeedCheckIfNeeded(on: self.updateController.viewModel) {
                    return
                }
                self.checkForUpdates(nil)
            }
        }

        // In UI tests, `WindowGroup` occasionally fails to materialize a window quickly on the VM.
        // If there are no windows shortly after launch, force-create one so XCUITest can proceed.
        if isRunningUnderXCTest {
            if let rawVariant = env["CMUX_UI_TEST_BROWSER_IMPORT_HINT_VARIANT"] {
                UserDefaults.standard.set(
                    BrowserImportHintSettings.variant(for: rawVariant).rawValue,
                    forKey: BrowserImportHintSettings.variantKey
                )
            }
            if let rawShow = env["CMUX_UI_TEST_BROWSER_IMPORT_HINT_SHOW"] {
                UserDefaults.standard.set(
                    rawShow == "1",
                    forKey: BrowserImportHintSettings.showOnBlankTabsKey
                )
            }
            if let rawDismissed = env["CMUX_UI_TEST_BROWSER_IMPORT_HINT_DISMISSED"] {
                UserDefaults.standard.set(
                    rawDismissed == "1",
                    forKey: BrowserImportHintSettings.dismissedKey
                )
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                if NSApp.windows.isEmpty {
                    self.openNewMainWindow(nil)
                }
                self.moveUITestWindowToTargetDisplayIfNeeded()
                NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                // On headless CI runners, activate() silently fails (no GUI session).
                // Force windows visible so the terminal surface starts rendering.
                for window in NSApp.windows {
                    window.orderFrontRegardless()
                }
                self.writeUITestDiagnosticsIfNeeded(stage: "afterForceWindow")
            }
            if env["CMUX_UI_TEST_BROWSER_IMPORT_HINT_OPEN_BLANK_BROWSER"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                    guard let self else { return }
                    _ = self.openBrowserAndFocusAddressBar(insertAtEnd: true)
                }
            }
            if env["CMUX_UI_TEST_BROWSER_IMPORT_HINT_OPEN_SETTINGS"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
                    self?.openPreferencesWindow(
                        debugSource: "uiTest.browserImportHint",
                        navigationTarget: .browser
                    )
                }
            }
            if env["CMUX_UI_TEST_BROWSER_IMPORT_AUTO_OPEN"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    BrowserDataImportCoordinator.shared.presentImportDialog()
                }
            }
        }
#endif
    }

#if DEBUG
    private func writeUITestDiagnosticsIfNeeded(stage: String) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CMUX_UI_TEST_DIAGNOSTICS_PATH"], !path.isEmpty else { return }

        var payload = loadUITestDiagnostics(at: path)
        let isRunningUnderXCTest = isRunningUnderXCTest(env)

        let windows = NSApp.windows
        let ids = windows.map { $0.identifier?.rawValue ?? "" }.joined(separator: ",")
        let vis = windows.map { $0.isVisible ? "1" : "0" }.joined(separator: ",")
        let screenIDs = windows.map { $0.screen?.cmuxDisplayID.map(String.init) ?? "" }.joined(separator: ",")
        let targetDisplayID = env["CMUX_UI_TEST_TARGET_DISPLAY_ID"] ?? ""

        payload["stage"] = stage
        payload["pid"] = String(ProcessInfo.processInfo.processIdentifier)
        payload["bundleId"] = Bundle.main.bundleIdentifier ?? ""
        payload["isRunningUnderXCTest"] = isRunningUnderXCTest ? "1" : "0"
        payload["windowsCount"] = String(windows.count)
        payload["windowIdentifiers"] = ids
        payload["windowVisibleFlags"] = vis
        payload["windowScreenDisplayIDs"] = screenIDs
        payload["uiTestTargetDisplayID"] = targetDisplayID
        if let rawDisplayID = UInt32(targetDisplayID) {
            let screenPresent = NSScreen.screens.contains(where: { $0.cmuxDisplayID == rawDisplayID })
            let movedWindow = windows.contains(where: { $0.screen?.cmuxDisplayID == rawDisplayID })
            payload["targetDisplayPresent"] = screenPresent ? "1" : "0"
            payload["targetDisplayMoveSucceeded"] = movedWindow ? "1" : "0"
        }
        appendUITestRenderDiagnosticsIfNeeded(&payload, environment: env)
        appendUITestSocketDiagnosticsIfNeeded(&payload, environment: env)

        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func loadUITestDiagnostics(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

    private func appendUITestSocketDiagnosticsIfNeeded(
        _ payload: inout [String: String],
        environment env: [String: String]
    ) {
        guard env["CMUX_UI_TEST_SOCKET_SANITY"] == "1" else { return }

        guard let config = socketListenerConfigurationIfEnabled() else {
            payload["socketExpectedPath"] = env["CMUX_SOCKET_PATH"] ?? ""
            payload["socketMode"] = "off"
            payload["socketReady"] = "0"
            payload["socketPingResponse"] = ""
            payload["socketIsRunning"] = "0"
            payload["socketAcceptLoopAlive"] = "0"
            payload["socketPathMatches"] = "0"
            payload["socketPathExists"] = "0"
            payload["socketFailureSignals"] = "socket_disabled"
            return
        }

        let socketPath = TerminalController.shared.activeSocketPath(preferredPath: config.path)
        let health = TerminalController.shared.socketListenerHealth(expectedSocketPath: socketPath)
        let pingResponse = health.isHealthy
            ? TerminalController.probeSocketCommand("ping", at: socketPath, timeout: 1.0)
            : nil
        let isReady = health.isHealthy && pingResponse == "PONG"
        var failureSignals = health.failureSignals
        if health.isHealthy && pingResponse != "PONG" {
            failureSignals.append("ping_timeout")
        }

        payload["socketExpectedPath"] = socketPath
        payload["socketMode"] = config.mode.rawValue
        payload["socketReady"] = isReady ? "1" : "0"
        payload["socketPingResponse"] = pingResponse ?? ""
        payload["socketIsRunning"] = health.isRunning ? "1" : "0"
        payload["socketAcceptLoopAlive"] = health.acceptLoopAlive ? "1" : "0"
        payload["socketPathMatches"] = health.socketPathMatches ? "1" : "0"
        payload["socketPathExists"] = health.socketPathExists ? "1" : "0"
        payload["socketFailureSignals"] = failureSignals.joined(separator: ",")
    }

    private func appendUITestRenderDiagnosticsIfNeeded(
        _ payload: inout [String: String],
        environment env: [String: String]
    ) {
        guard env["CMUX_UI_TEST_DISPLAY_RENDER_STATS"] == "1" else { return }

        guard let renderState = currentUITestRenderDiagnostics() else {
            payload["renderStatsAvailable"] = "0"
            payload["renderPanelId"] = ""
            payload["renderDrawCount"] = ""
            payload["renderPresentCount"] = ""
            payload["renderLastPresentTime"] = ""
            payload["renderWindowVisible"] = ""
            payload["renderAppIsActive"] = ""
            payload["renderDesiredFocus"] = ""
            payload["renderIsFirstResponder"] = ""
            payload["renderDiagnosticsUpdatedAt"] = String(format: "%.6f", ProcessInfo.processInfo.systemUptime)
            return
        }

        payload["renderStatsAvailable"] = "1"
        payload["renderPanelId"] = renderState.panelId.uuidString
        payload["renderDrawCount"] = String(renderState.drawCount)
        payload["renderPresentCount"] = String(renderState.presentCount)
        payload["renderLastPresentTime"] = String(format: "%.6f", renderState.lastPresentTime)
        payload["renderWindowVisible"] = renderState.windowVisible ? "1" : "0"
        payload["renderAppIsActive"] = renderState.appIsActive ? "1" : "0"
        payload["renderDesiredFocus"] = renderState.desiredFocus ? "1" : "0"
        payload["renderIsFirstResponder"] = renderState.isFirstResponder ? "1" : "0"
        payload["renderDiagnosticsUpdatedAt"] = String(format: "%.6f", ProcessInfo.processInfo.systemUptime)
    }

    private func currentUITestRenderDiagnostics() -> UITestRenderDiagnosticsSnapshot? {
        guard let tabManager,
              let tabId = tabManager.selectedTabId,
              let workspace = tabManager.tabs.first(where: { $0.id == tabId }) else {
            return nil
        }

        let terminalPanel: TerminalPanel? = {
            if let focusedPanelId = workspace.focusedPanelId,
               let terminalPanel = workspace.terminalPanel(for: focusedPanelId) {
                return terminalPanel
            }
            if let focusedTerminalPanel = workspace.focusedTerminalPanel {
                return focusedTerminalPanel
            }
            return workspace.panels.values.compactMap { $0 as? TerminalPanel }.first
        }()

        guard let terminalPanel else { return nil }
        let stats = terminalPanel.hostedView.debugRenderStats()
        return UITestRenderDiagnosticsSnapshot(
            panelId: terminalPanel.id,
            drawCount: stats.drawCount,
            presentCount: stats.presentCount,
            lastPresentTime: stats.lastPresentTime,
            windowVisible: stats.windowOcclusionVisible,
            appIsActive: stats.appIsActive,
            desiredFocus: stats.desiredFocus,
            isFirstResponder: stats.isFirstResponder
        )
    }

    private func moveUITestWindowToTargetDisplayIfNeeded(attempt: Int = 0) {
        let env = ProcessInfo.processInfo.environment
        guard let rawDisplayID = env["CMUX_UI_TEST_TARGET_DISPLAY_ID"],
              let targetDisplayID = UInt32(rawDisplayID) else {
            return
        }

        guard let screen = NSScreen.screens.first(where: { $0.cmuxDisplayID == targetDisplayID }) else {
            if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.moveUITestWindowToTargetDisplayIfNeeded(attempt: attempt + 1)
                }
            }
            self.writeUITestDiagnosticsIfNeeded(stage: "targetDisplayMissing")
            return
        }

        guard let window = NSApp.windows.first else {
            if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.moveUITestWindowToTargetDisplayIfNeeded(attempt: attempt + 1)
                }
            }
            self.writeUITestDiagnosticsIfNeeded(stage: "targetDisplayNoWindow")
            return
        }

        let visibleFrame = screen.visibleFrame
        let width = min(window.frame.width, max(visibleFrame.width - 80, 480))
        let height = min(window.frame.height, max(visibleFrame.height - 80, 360))
        let frame = NSRect(
            x: visibleFrame.midX - (width / 2),
            y: visibleFrame.midY - (height / 2),
            width: width,
            height: height
        ).integral

        window.setFrame(frame, display: true, animate: false)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        if window.screen?.cmuxDisplayID != targetDisplayID, attempt < 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.moveUITestWindowToTargetDisplayIfNeeded(attempt: attempt + 1)
            }
            return
        }
        self.writeUITestDiagnosticsIfNeeded(stage: "afterMoveToTargetDisplay")
    }
#endif

    func applicationDidBecomeActive(_ notification: Notification) {
        sentryBreadcrumb("app.didBecomeActive", category: "lifecycle", data: [
            "tabCount": tabManager?.tabs.count ?? 0
        ])
        if TelemetrySettings.enabledForCurrentLaunch && !isRunningUnderXCTestCached {
            PostHogAnalytics.shared.trackActive(reason: "didBecomeActive")
        }

        guard let notificationStore else { return }
        notificationStore.handleApplicationDidBecomeActive()
        guard let tabManager else { return }
        guard let tabId = tabManager.selectedTabId else { return }
        let surfaceId = tabManager.focusedSurfaceId(for: tabId)
        guard notificationStore.hasUnreadNotification(forTabId: tabId, surfaceId: surfaceId) else { return }

        if let surfaceId,
           let tab = tabManager.tabs.first(where: { $0.id == tabId }) {
            tab.triggerNotificationFocusFlash(panelId: surfaceId, requiresSplit: false, shouldFocus: false)
        }
        notificationStore.markRead(forTabId: tabId, surfaceId: surfaceId)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isTerminatingApp = true
        _ = saveSessionSnapshot(includeScrollback: true, removeWhenEmpty: false)

        // Tagged DEV builds are ephemeral, skip quit confirmation entirely.
        if SocketControlSettings.isTaggedDevBuild() {
            return .terminateNow
        }

        // If the user already confirmed via the Cmd+Q shortcut warning dialog
        // (handleQuitShortcutWarning), skip the check to avoid a second alert.
        if isQuitWarningConfirmed {
            return .terminateNow
        }

        // Respect the "Warn Before Quit" setting even when Cmd+Q arrives via
        // the Cmd+Tab app switcher, bypassing handleCustomShortcut.
        guard QuitWarningSettings.isEnabled() else {
            return .terminateNow
        }

        // Show the same confirmation dialog used by the Cmd+Q shortcut path,
        // then reply asynchronously so we can return .terminateLater now.
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "dialog.quitCmux.title", defaultValue: "Quit cmux?")
            alert.informativeText = String(localized: "dialog.quitCmux.message", defaultValue: "This will close all windows and workspaces.")
            alert.addButton(withTitle: String(localized: "dialog.quitCmux.quit", defaultValue: "Quit"))
            alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = String(localized: "dialog.dontWarnCmdQ", defaultValue: "Don't warn again for Cmd+Q")

            let response = alert.runModal()
            if alert.suppressionButton?.state == .on {
                QuitWarningSettings.setEnabled(false)
            }

            let shouldQuit = response == .alertFirstButtonReturn
            if shouldQuit {
                self.isQuitWarningConfirmed = true
            } else {
                // Reset so that the next quit attempt can show the dialog again.
                self.isTerminatingApp = false
            }
            NSApp.reply(toApplicationShouldTerminate: shouldQuit)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminatingApp = true
        _ = saveSessionSnapshot(includeScrollback: true, removeWhenEmpty: false)
        stopSessionAutosaveTimer()
        TerminalController.shared.stop()
        VSCodeServeWebController.shared.stop()
        BrowserProfileStore.shared.flushPendingSaves()
        if TelemetrySettings.enabledForCurrentLaunch {
            PostHogAnalytics.shared.flush()
        }
        notificationStore?.clearAll()
        enableSuddenTerminationIfNeeded()
    }

    func applicationWillResignActive(_ notification: Notification) {
        guard !isTerminatingApp else { return }
        clearConfiguredShortcutChordState()
        _ = saveSessionSnapshot(includeScrollback: false)
    }

    func persistSessionForUpdateRelaunch() {
        isTerminatingApp = true
        _ = saveSessionSnapshot(includeScrollback: true, removeWhenEmpty: false)
    }

    func configure(tabManager: TabManager, notificationStore: TerminalNotificationStore, sidebarState: SidebarState) {
        self.tabManager = tabManager
        self.notificationStore = notificationStore
        self.sidebarState = sidebarState
        disableSuddenTerminationIfNeeded()
        installLifecycleSnapshotObserversIfNeeded()
        prepareStartupSessionSnapshotIfNeeded()
        startSessionAutosaveTimerIfNeeded()
#if DEBUG
        setupJumpUnreadUITestIfNeeded()
        setupTerminalCmdClickUITestIfNeeded()
        setupGotoSplitUITestIfNeeded()
        setupBonsplitTabDragUITestIfNeeded()
        setupMultiWindowNotificationsUITestIfNeeded()
        setupDisplayResolutionUITestDiagnosticsIfNeeded()

        // UI tests sometimes don't run SwiftUI `.onAppear` soon enough (or at all) on the VM.
        // The automation socket is a core testing primitive, so ensure it's started here when
        // we detect XCTest, even if the main view lifecycle is flaky.
        let env = ProcessInfo.processInfo.environment
        if isRunningUnderXCTest(env) {
            let raw = UserDefaults.standard.string(forKey: SocketControlSettings.appStorageKey)
                ?? SocketControlSettings.defaultMode.rawValue
            let userMode = SocketControlSettings.migrateMode(raw)
            let mode = SocketControlSettings.effectiveMode(userMode: userMode)
            if mode != .off {
                TerminalController.shared.start(
                    tabManager: tabManager,
                    socketPath: SocketControlSettings.socketPath(),
                    accessMode: mode
                )
                scheduleUITestSocketSanityCheckIfNeeded()
            }
        }
#endif
    }

#if DEBUG
    private func setupTerminalCmdClickUITestIfNeeded() {
        guard !didSetupTerminalCmdClickUITest else { return }

        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_SETUP"] == "1" else {
            dlog("cmdclick.ui.setup skip reason=env_missing tag=\(env["CMUX_TAG"] ?? "nil")")
            return
        }
        guard let manifestPath = env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !manifestPath.isEmpty else {
            dlog("cmdclick.ui.setup skip reason=missing_manifest_path")
            return
        }
        didSetupTerminalCmdClickUITest = true
        guard let fixtureDirectory = env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_FIXTURE_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !fixtureDirectory.isEmpty else {
            dlog("cmdclick.ui.setup error reason=missing_fixture_dir manifest=\(manifestPath)")
            writeTerminalCmdClickUITestData(at: manifestPath, updates: [
                "setupError": "Missing fixture directory"
            ])
            return
        }
        let commandPath = env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_COMMAND_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayMode = env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_DISPLAY_MODE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lineFormat = env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_LINE_FORMAT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let linePrefix = env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_LINE_PREFIX"] ?? ""
        let extraFileNamesJSON = env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_EXTRA_FILE_NAMES_JSON"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let fileName = env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_FILE_NAME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedFileName = (fileName?.isEmpty == false) ? fileName! : "Cmd Click Fixture.txt"
        let fixtureDirectoryURL = URL(fileURLWithPath: fixtureDirectory, isDirectory: true)
        let expectedFileURL = fixtureDirectoryURL.appendingPathComponent(resolvedFileName)
        let siblingFileURL = fixtureDirectoryURL.appendingPathComponent("OtherFile")
        let extraFileNames: [String]
        if let extraFileNamesJSON,
           let data = extraFileNamesJSON.data(using: .utf8),
           let values = try? JSONSerialization.jsonObject(with: data) as? [String] {
            extraFileNames = values
        } else {
            extraFileNames = []
        }
        let escapedToken = resolvedFileName.replacingOccurrences(of: " ", with: "\\ ")
        let resolvedDisplayMode = (displayMode == "raw") ? "raw" : "escaped"
        let resolvedLineFormat: String
        switch lineFormat {
        case "log":
            resolvedLineFormat = "log"
        case "alt_screen_log":
            resolvedLineFormat = "alt_screen_log"
        default:
            resolvedLineFormat = "grid"
        }
        dlog(
            "cmdclick.ui.setup start manifest=\(manifestPath) fixture=\(fixtureDirectory) " +
                "command=\(commandPath ?? "nil") display=\(resolvedDisplayMode) " +
                "lineFormat=\(resolvedLineFormat) " +
                "file=\(resolvedFileName)"
        )
        func singleQuotedShellLiteral(_ text: String) -> String {
            text.replacingOccurrences(of: "'", with: "'\"'\"'")
        }
        let displayToken: String
        let shellCommand: String
        switch resolvedLineFormat {
        case "log":
            displayToken = resolvedFileName
            let blockLine = "\(linePrefix)\(resolvedFileName)"
            let shellBlockLine = singleQuotedShellLiteral(blockLine)
            shellCommand = "clear\rfor i in $(seq 1 48); do printf '%s\\n' '\(shellBlockLine)'; done\r"
        case "alt_screen_log":
            displayToken = resolvedFileName
            let blockLine = "\(linePrefix)\(resolvedFileName)"
            let shellBlockLine = singleQuotedShellLiteral(blockLine)
            shellCommand = "clear\rprintf '\\033[?1049h\\033[H\\033[2J'; for i in $(seq 1 48); do printf '%s\\n' '\(shellBlockLine)'; done\r"
        default:
            switch resolvedDisplayMode {
            case "raw":
                displayToken = resolvedFileName
                let blockLine = "\(resolvedFileName)    OtherFile"
                let shellBlockLine = singleQuotedShellLiteral(blockLine)
                shellCommand = "clear\rfor i in $(seq 1 48); do printf '%s\\n' '\(shellBlockLine)'; done\r"
            default:
                displayToken = escapedToken
                let blockLine = Array(repeating: escapedToken, count: 3).joined(separator: " ")
                let shellBlockLine = singleQuotedShellLiteral(blockLine)
                shellCommand = "clear\rfor i in $(seq 1 48); do printf '%s\\n' '\(shellBlockLine)'; done\r"
            }
        }
        let deadline = Date().addingTimeInterval((commandPath?.isEmpty == false) ? 60.0 : 20.0)
        var seeded = false
        var resolved = false
        var tokenPointPayload: [String: Any]?
        var observers: [NSObjectProtocol] = []
        var lastHandledCommandID: String?

        func rectPayload(_ rect: CGRect) -> [String: Double] {
            [
                "x": rect.origin.x,
                "y": rect.origin.y,
                "width": rect.size.width,
                "height": rect.size.height
            ]
        }

        func pointPayload(x: CGFloat, yFromTop: CGFloat) -> [String: Double] {
            [
                "x": x,
                "y": yFromTop
            ]
        }

        func pointFromPayload(_ key: String, in terminalPanel: TerminalPanel) -> NSPoint? {
            guard let payload = tokenPointPayload?[key] as? [String: Any],
                  let x = payload["x"] as? Double,
                  let yFromTop = payload["y"] as? Double else {
                return nil
            }

            let clampedX = min(max(CGFloat(x), 1), max(terminalPanel.hostedView.bounds.width - 1, 1))
            let clampedYFromTop = min(
                max(CGFloat(yFromTop), 1),
                max(terminalPanel.hostedView.bounds.height - 1, 1)
            )
            return NSPoint(
                x: clampedX,
                y: terminalPanel.hostedView.bounds.height - clampedYFromTop
            )
        }

        func pointForTokenColumnOffset(_ offset: Int, in terminalPanel: TerminalPanel) -> NSPoint? {
            guard let selectionStart = pointFromPayload("tokenSelectionStartInTerminal", in: terminalPanel),
                  let tokenCellMetrics = tokenPointPayload?["tokenCellMetrics"] as? [String: Any],
                  let cellWidth = tokenCellMetrics["cellWidth"] as? Double else {
                return nil
            }

            let unclampedX = selectionStart.x + (CGFloat(offset) * CGFloat(cellWidth))
            let clampedX = min(max(unclampedX, 1), max(terminalPanel.hostedView.bounds.width - 1, 1))
            return NSPoint(x: clampedX, y: selectionStart.y)
        }

        func commandPoint(
            from command: [String: Any],
            defaultPayloadKey: String,
            in terminalPanel: TerminalPanel
        ) -> NSPoint? {
            if let tokenColumnOffset = command["tokenColumnOffset"] as? Int {
                return pointForTokenColumnOffset(tokenColumnOffset, in: terminalPanel)
            }
            if let tokenColumnOffset = command["tokenColumnOffset"] as? NSNumber {
                return pointForTokenColumnOffset(tokenColumnOffset.intValue, in: terminalPanel)
            }
            return pointFromPayload(defaultPayloadKey, in: terminalPanel)
        }

        func loadCommand(at path: String) -> [String: Any]? {
            let url = URL(fileURLWithPath: path)
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return object
        }

        func tokenPoints(in terminalPanel: TerminalPanel, visibleText: String) -> [String: Any]? {
            guard let surface = terminalPanel.surface.surface else { return nil }
            let bounds = terminalPanel.hostedView.bounds
            guard bounds.width > 0, bounds.height > 0 else { return nil }

            let size = ghostty_surface_size(surface)
            let rows = max(Int(size.rows), 1)
            let cols = max(Int(size.columns), 1)
            let debugCellSize = terminalPanel.hostedView.debugCellSize
            let cellWidth = debugCellSize.width > 0 ? debugCellSize.width : CGFloat(size.cell_width_px)
            let cellHeight = debugCellSize.height > 0 ? debugCellSize.height : CGFloat(size.cell_height_px)
            guard cellWidth > 0, cellHeight > 0 else { return nil }

            let xInset = max(0, (bounds.width - (CGFloat(cols) * cellWidth)) / 2)
            let yInset = max(0, (bounds.height - (CGFloat(rows) * cellHeight)) / 2)
            let pointClampX: (CGFloat) -> CGFloat = { x in
                min(bounds.width - 4, max(4, x))
            }
            let pointClampY: (CGFloat) -> CGFloat = { y in
                min(bounds.height - 4, max(4, y))
            }

            let rawVisibleLines = visibleText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let visibleLines = rawVisibleLines.count > rows ? Array(rawVisibleLines.suffix(rows)) : rawVisibleLines
            let rowOffset = max(0, rows - visibleLines.count)

            var matchedRowFromTop: Int?
            var matchedColumnStart: Int?
            var matchedColumnEnd: Int?
            var matchedLine = ""
            var matchingLines: [(lineIndex: Int, line: String, ranges: [Range<String.Index>])] = []

            for (lineIndex, line) in visibleLines.enumerated() {
                var searchStart = line.startIndex
                var ranges: [Range<String.Index>] = []
                while searchStart < line.endIndex,
                      let range = line.range(of: displayToken, range: searchStart..<line.endIndex) {
                    ranges.append(range)
                    searchStart = range.upperBound
                }
                if !ranges.isEmpty {
                    matchingLines.append((lineIndex, line, ranges))
                }
            }

            if !matchingLines.isEmpty {
                let selectedLine = matchingLines[matchingLines.count / 2]
                let selectedRange = selectedLine.ranges[selectedLine.ranges.count / 2]
                let startColumn = selectedLine.line.distance(from: selectedLine.line.startIndex, to: selectedRange.lowerBound)
                let endColumnExclusive = selectedLine.line.distance(from: selectedLine.line.startIndex, to: selectedRange.upperBound)
                if startColumn < cols {
                    matchedRowFromTop = rowOffset + selectedLine.lineIndex
                    matchedColumnStart = startColumn
                    matchedColumnEnd = max(startColumn, endColumnExclusive - 1)
                    matchedLine = selectedLine.line
                }
            }

            guard let matchedRowFromTop,
                  let matchedColumnStart,
                  let matchedColumnEnd else {
                return [
                    "tokenLayoutMatch": "0",
                    "tokenCellMetrics": [
                        "cellWidth": cellWidth,
                        "cellHeight": cellHeight,
                        "columns": cols,
                        "rows": rows,
                        "xInset": xInset,
                        "yInset": yInset,
                        "visibleLineCount": visibleLines.count
                    ]
                ]
            }

            let yFromTop = pointClampY(yInset + (CGFloat(matchedRowFromTop) * cellHeight) + (cellHeight / 2))
            let startX = pointClampX(xInset + (CGFloat(matchedColumnStart) * cellWidth) + (cellWidth / 2))
            let endX = pointClampX(xInset + (CGFloat(matchedColumnEnd) * cellWidth) + (cellWidth / 2))
            let hitX = pointClampX(startX + min(cellWidth * 2, max(0, endX - startX)))
            return [
                "tokenHitPointInTerminal": pointPayload(x: hitX, yFromTop: yFromTop),
                "tokenSelectionStartInTerminal": pointPayload(x: startX, yFromTop: yFromTop),
                "tokenSelectionEndInTerminal": pointPayload(x: endX, yFromTop: yFromTop),
                "tokenQuicklookWord": displayToken,
                "tokenLayoutMatch": "1",
                "tokenCellMetrics": [
                    "cellWidth": cellWidth,
                    "cellHeight": cellHeight,
                    "columns": cols,
                    "rows": rows,
                    "xInset": xInset,
                    "yInset": yInset,
                    "visibleLineCount": visibleLines.count,
                    "matchedRowFromTop": matchedRowFromTop,
                    "matchedColumnStart": matchedColumnStart,
                    "matchedColumnEnd": matchedColumnEnd,
                    "matchedLine": matchedLine
                ]
            ]
        }

        func cleanup() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            terminalCmdClickUITestPoller?.cancel()
            terminalCmdClickUITestPoller = nil
        }

        func writeState(
            terminalPanel: TerminalPanel?,
            window: NSWindow?,
            ready: Bool,
            setupError: String? = nil,
            additionalPayload: [String: Any] = [:]
        ) {
            var payload: [String: Any] = [
                "ready": ready ? "1" : "0",
                "escapedToken": escapedToken,
                "displayMode": resolvedDisplayMode,
                "lineFormat": resolvedLineFormat,
                "displayToken": displayToken,
                "fileName": resolvedFileName,
                "expectedPath": expectedFileURL.path,
                "fixtureDirectory": fixtureDirectoryURL.path
            ]
            if let terminalPanel {
                let terminalFrame = terminalPanel.hostedView.debugPortalFrameInWindow
                payload["surfaceId"] = terminalPanel.id.uuidString
                payload["terminalVisibleInUI"] = terminalPanel.hostedView.debugPortalVisibleInUI ? "1" : "0"
                payload["terminalFrameInWindow"] = rectPayload(terminalFrame)
            }
            if let window {
                payload["windowFrame"] = rectPayload(window.frame)
                payload["windowVisible"] = window.isVisible ? "1" : "0"
            }
            if let setupError {
                payload["setupError"] = setupError
            }
            if let tokenPointPayload {
                for (key, value) in tokenPointPayload {
                    payload[key] = value
                }
            }
            for (key, value) in additionalPayload {
                payload[key] = value
            }
            writeTerminalCmdClickUITestData(at: manifestPath, updates: payload)
        }

        func resizeWindowIfNeeded(_ window: NSWindow) {
            let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            guard let screenFrame else { return }
            let targetSize = NSSize(
                width: min(960, screenFrame.width - 80),
                height: min(720, screenFrame.height - 80)
            )
            let targetOrigin = NSPoint(
                x: screenFrame.minX + 40,
                y: screenFrame.maxY - 40 - targetSize.height
            )
            let targetFrame = NSRect(origin: targetOrigin, size: targetSize)
            if !window.frame.equalTo(targetFrame) {
                window.setFrame(targetFrame, display: true)
            }
        }

        @MainActor
        func executePendingCommandIfNeeded(
            terminalPanel: TerminalPanel,
            window: NSWindow
        ) {
            guard let commandPath,
                  !commandPath.isEmpty,
                  let command = loadCommand(at: commandPath),
                  let commandID = command["id"] as? String,
                  commandID != lastHandledCommandID else {
                return
            }

            let action = (command["action"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var payload: [String: Any] = [
                "lastCommandId": commandID,
                "lastCommandAction": action,
                "lastCommandSucceeded": "0"
            ]

            switch action {
            case "hover_token":
                guard let hitPoint = commandPoint(
                    from: command,
                    defaultPayloadKey: "tokenHitPointInTerminal",
                    in: terminalPanel
                ) else {
                    payload["lastCommandError"] = "Missing command point"
                    break
                }

                let result = terminalPanel.hostedView.debugSimulateCommandHoverDetails(at: hitPoint)
                payload["lastCommandResult"] = result
                payload["lastCommandHoverActive"] = result["hoverActive"]
                if let resolvedPath = result["resolvedPath"] as? String {
                    payload["lastCommandResolvedPath"] = resolvedPath
                    payload["lastCommandSucceeded"] = "1"
                } else if let error = result["error"] as? String {
                    payload["lastCommandError"] = error
                } else {
                    payload["lastCommandError"] = "Command hover did not resolve a path"
                }

            case "cmd_click_token":
                guard let hitPoint = commandPoint(
                    from: command,
                    defaultPayloadKey: "tokenHitPointInTerminal",
                    in: terminalPanel
                ) else {
                    payload["lastCommandError"] = "Missing command point"
                    break
                }

                let result = terminalPanel.hostedView.debugSimulateCommandClick(at: hitPoint)
                payload["lastCommandResult"] = result
                if let openedPath = result["openedPath"] as? String {
                    payload["lastCommandOpenedPath"] = openedPath
                    payload["lastCommandSucceeded"] = "1"
                } else if let error = result["error"] as? String {
                    payload["lastCommandError"] = error
                } else {
                    payload["lastCommandError"] = "Command click did not open a path"
                }

            case "select_token_and_hold_command":
                guard let selectionStart = pointFromPayload("tokenSelectionStartInTerminal", in: terminalPanel),
                      let selectionEnd = pointFromPayload("tokenSelectionEndInTerminal", in: terminalPanel) else {
                    payload["lastCommandError"] = "Missing token selection points"
                    break
                }

                let selectionActive = terminalPanel.hostedView.debugSimulateSelection(
                    from: selectionStart,
                    to: selectionEnd
                )
                let hoverSuppressed = terminalPanel.hostedView.debugSimulateCommandHover(at: selectionEnd)
                payload["lastCommandSelectionActive"] = selectionActive ? "1" : "0"
                payload["lastCommandHoverSuppressed"] = hoverSuppressed ? "1" : "0"
                if selectionActive && hoverSuppressed {
                    payload["lastCommandSucceeded"] = "1"
                } else {
                    payload["lastCommandError"] = "Selection or hover suppression failed"
                }

            default:
                payload["lastCommandError"] = "Unknown command action: \(action)"
            }

            writeState(
                terminalPanel: terminalPanel,
                window: window,
                ready: true,
                additionalPayload: payload
            )
            lastHandledCommandID = commandID
        }

        @MainActor
        func evaluate() {
            guard !resolved else { return }
            let currentTabManager = self.tabManager
            let workspace = currentTabManager?.selectedWorkspace ?? currentTabManager?.tabs.first
            let terminalPanel = workspace?.focusedTerminalPanel
            let mainWindow = terminalPanel?.hostedView.window
                ?? currentTabManager.flatMap { self.windowId(for: $0).flatMap { self.mainWindow(for: $0) } }
            if Date() >= deadline {
                let textSnapshot = terminalPanel
                    .flatMap { TerminalController.shared.readTerminalTextForSnapshot(terminalPanel: $0, lineLimit: 200) } ?? ""
                var timeoutPayload: [String: Any] = [:]
                if let currentTabManager {
                    timeoutPayload["tabManager"] = debugManagerToken(currentTabManager)
                    timeoutPayload["workspaceCount"] = currentTabManager.tabs.count
                }
                let waitingFor = [
                    workspace == nil ? "workspace" : nil,
                    terminalPanel == nil ? "terminalPanel" : nil,
                    mainWindow == nil ? "mainWindow" : nil
                ]
                    .compactMap { $0 }
                    .joined(separator: ",")
                if !waitingFor.isEmpty {
                    timeoutPayload["waitingFor"] = waitingFor
                }
                writeState(
                    terminalPanel: terminalPanel,
                    window: mainWindow,
                    ready: false,
                    setupError: "Timed out waiting for terminal cmd-click setup. text=\(textSnapshot)",
                    additionalPayload: timeoutPayload
                )
                resolved = true
                cleanup()
                return
            }

            if currentTabManager == nil {
                writeTerminalCmdClickUITestData(at: manifestPath, updates: [
                    "ready": "0",
                    "setupError": "Waiting for tab manager"
                ])
                return
            }

            guard let workspace,
                  let terminalPanel,
                  let mainWindow else {
                var waitingPayload: [String: Any] = [
                    "ready": "0",
                    "setupError": "Waiting for terminal workspace"
                ]
                if let currentTabManager {
                    waitingPayload["tabManager"] = debugManagerToken(currentTabManager)
                    waitingPayload["workspaceCount"] = currentTabManager.tabs.count
                }
                let waitingFor = [
                    workspace == nil ? "workspace" : nil,
                    terminalPanel == nil ? "terminalPanel" : nil,
                    mainWindow == nil ? "mainWindow" : nil
                ]
                    .compactMap { $0 }
                    .joined(separator: ",")
                if !waitingFor.isEmpty {
                    waitingPayload["waitingFor"] = waitingFor
                }
                writeTerminalCmdClickUITestData(at: manifestPath, updates: waitingPayload)
                return
            }

            resizeWindowIfNeeded(mainWindow)
            mainWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            terminalPanel.focus()

            do {
                try FileManager.default.createDirectory(
                    at: fixtureDirectoryURL,
                    withIntermediateDirectories: true
                )
                if !FileManager.default.fileExists(atPath: expectedFileURL.path) {
                    try "fixture\n".write(to: expectedFileURL, atomically: true, encoding: .utf8)
                }
                if !FileManager.default.fileExists(atPath: siblingFileURL.path) {
                    try "fixture\n".write(to: siblingFileURL, atomically: true, encoding: .utf8)
                }
                for extraFileName in extraFileNames where !extraFileName.isEmpty {
                    let extraFileURL = fixtureDirectoryURL.appendingPathComponent(extraFileName)
                    if !FileManager.default.fileExists(atPath: extraFileURL.path) {
                        try "fixture\n".write(to: extraFileURL, atomically: true, encoding: .utf8)
                    }
                }
            } catch {
                writeState(
                    terminalPanel: terminalPanel,
                    window: mainWindow,
                    ready: false,
                    setupError: "Failed to create fixture: \(error.localizedDescription)"
                )
                resolved = true
                cleanup()
                return
            }

            workspace.updatePanelDirectory(panelId: terminalPanel.id, directory: fixtureDirectoryURL.path)

            let terminalFrame = terminalPanel.hostedView.debugPortalFrameInWindow
            let terminalReady = terminalPanel.surface.surface != nil
            let terminalVisible = terminalPanel.hostedView.window != nil &&
                terminalPanel.hostedView.debugPortalVisibleInUI &&
                !terminalFrame.isEmpty &&
                terminalFrame.width > 0 &&
                terminalFrame.height > 0

            if terminalReady && terminalVisible && !seeded {
                seeded = true
                sendTextWhenReady(shellCommand, to: workspace) {
                    workspace.updatePanelDirectory(panelId: terminalPanel.id, directory: fixtureDirectoryURL.path)
                }
            }

            let visibleText = TerminalController.shared.readTerminalTextForSnapshot(
                terminalPanel: terminalPanel,
                lineLimit: 200
            ) ?? ""
            let renderedTokenCount = max(0, visibleText.components(separatedBy: displayToken).count - 1)
            let hasRenderedToken = renderedTokenCount >= 6
            if hasRenderedToken,
               (tokenPointPayload?["tokenLayoutMatch"] as? String) != "1" {
                tokenPointPayload = tokenPoints(in: terminalPanel, visibleText: visibleText)
            }
            let tokenLayoutReady = (tokenPointPayload?["tokenLayoutMatch"] as? String) == "1"

            writeState(
                terminalPanel: terminalPanel,
                window: mainWindow,
                ready: terminalReady && terminalVisible && hasRenderedToken && tokenLayoutReady,
                additionalPayload: [
                    "seeded": seeded ? "1" : "0",
                    "hasRenderedToken": hasRenderedToken ? "1" : "0",
                    "renderedTokenCount": renderedTokenCount,
                    "visibleTextTail": String(visibleText.suffix(1200))
                ]
            )

            guard terminalReady, terminalVisible, hasRenderedToken, tokenLayoutReady else { return }
            if commandPath?.isEmpty == false {
                executePendingCommandIfNeeded(
                    terminalPanel: terminalPanel,
                    window: mainWindow
                )
                return
            }
            resolved = true
            cleanup()
        }

        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in evaluate() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .terminalSurfaceHostedViewDidMoveToWindow,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in evaluate() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in evaluate() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusSurface,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in evaluate() }
        })
        let poller = DispatchSource.makeTimerSource(queue: .main)
        poller.schedule(deadline: .now(), repeating: .milliseconds(100))
        poller.setEventHandler {
            Task { @MainActor in evaluate() }
        }
        terminalCmdClickUITestPoller = poller
        dlog("cmdclick.ui.setup poller_started manifest=\(manifestPath)")
        poller.resume()
    }

    private func writeTerminalCmdClickUITestData(at path: String, updates: [String: Any]) {
        let url = URL(fileURLWithPath: path)
        var payload: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            payload = object
        }
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            dlog("cmdclick.ui.write skip reason=json path=\(path)")
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            dlog("cmdclick.ui.write error path=\(path) error=\(error.localizedDescription)")
        }
    }

    private func scheduleUITestSocketSanityCheckIfNeeded() {
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_SOCKET_SANITY"] == "1" else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            guard let self else { return }
            guard let config = self.socketListenerConfigurationIfEnabled() else {
                self.writeUITestDiagnosticsIfNeeded(stage: "socketSanityDisabled")
                return
            }

            let expectedPath = TerminalController.shared.activeSocketPath(preferredPath: config.path)
            let health = TerminalController.shared.socketListenerHealth(expectedSocketPath: expectedPath)
            let pingResponse = health.isHealthy
                ? TerminalController.probeSocketCommand("ping", at: expectedPath, timeout: 1.0)
                : nil
            let isReady = health.isHealthy && pingResponse == "PONG"
            if isReady {
                self.writeUITestDiagnosticsIfNeeded(stage: "socketSanityReady")
                return
            }

            self.writeUITestDiagnosticsIfNeeded(stage: "socketSanityRestart")
            self.restartSocketListenerIfEnabled(source: "uiTest.socketSanity")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
                self?.writeUITestDiagnosticsIfNeeded(stage: "socketSanityPostRestart")
            }
        }
    }

    private func setupDisplayResolutionUITestDiagnosticsIfNeeded() {
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_DISPLAY_RENDER_STATS"] == "1" else { return }
        guard !didSetupDisplayResolutionUITestDiagnostics else { return }
        didSetupDisplayResolutionUITestDiagnostics = true

        let center = NotificationCenter.default
        let observe: (Notification.Name, String) -> Void = { [weak self] name, stage in
            guard let self else { return }
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.writeUITestDiagnosticsIfNeeded(stage: stage)
                }
            }
            self.displayResolutionUITestObservers.append(observer)
        }

        observe(NSWindow.didResizeNotification, "displayUITest.windowDidResize")
        observe(NSWindow.didMoveNotification, "displayUITest.windowDidMove")
        observe(NSWindow.didChangeScreenNotification, "displayUITest.windowDidChangeScreen")
        observe(NSWindow.didChangeBackingPropertiesNotification, "displayUITest.windowDidChangeBacking")
        observe(.terminalSurfaceDidBecomeReady, "displayUITest.terminalSurfaceDidBecomeReady")
        observe(.terminalPortalVisibilityDidChange, "displayUITest.terminalPortalVisibilityDidChange")

        writeUITestDiagnosticsIfNeeded(stage: "displayUITest.setup")
    }
#endif

    private func prepareStartupSessionSnapshotIfNeeded() {
        guard !didPrepareStartupSessionSnapshot else { return }
        didPrepareStartupSessionSnapshot = true
        guard SessionRestorePolicy.shouldAttemptRestore() else { return }
        Self.removeLegacyPersistedWindowGeometry()
        startupSessionSnapshot = SessionPersistenceStore.load()
    }

    private func persistedWindowGeometry(
        defaults: UserDefaults = .standard
    ) -> PersistedWindowGeometry? {
        Self.removeLegacyPersistedWindowGeometry(defaults: defaults)
        guard let data = defaults.data(forKey: Self.persistedWindowGeometryDefaultsKey) else {
            return nil
        }
        guard let payload = Self.decodedPersistedWindowGeometryData(data) else {
            defaults.removeObject(forKey: Self.persistedWindowGeometryDefaultsKey)
            return nil
        }
        return payload
    }

    private func persistWindowGeometry(
        frame: SessionRectSnapshot?,
        display: SessionDisplaySnapshot?,
        defaults: UserDefaults = .standard
    ) {
        Self.removeLegacyPersistedWindowGeometry(defaults: defaults)
        guard let data = Self.encodedPersistedWindowGeometryData(frame: frame, display: display) else {
            return
        }
        defaults.set(data, forKey: Self.persistedWindowGeometryDefaultsKey)
    }

    private nonisolated static func encodedPersistedWindowGeometryData(
        frame: SessionRectSnapshot?,
        display: SessionDisplaySnapshot?
    ) -> Data? {
        guard let frame else { return nil }
        let payload = PersistedWindowGeometry(
            version: persistedWindowGeometrySchemaVersion,
            frame: frame,
            display: display
        )
        return try? JSONEncoder().encode(payload)
    }

    nonisolated static func decodedPersistedWindowGeometryData(_ data: Data) -> PersistedWindowGeometry? {
        guard let payload = try? JSONDecoder().decode(PersistedWindowGeometry.self, from: data),
              payload.version == persistedWindowGeometrySchemaVersion else {
            return nil
        }
        return payload
    }

    private nonisolated static func removeLegacyPersistedWindowGeometry(
        defaults: UserDefaults = .standard
    ) {
        legacyPersistedWindowGeometryDefaultsKeys.forEach { defaults.removeObject(forKey: $0) }
    }

    private func persistWindowGeometry(from window: NSWindow?) {
        guard let window else { return }
        persistWindowGeometry(
            frame: SessionRectSnapshot(window.frame),
            display: displaySnapshot(for: window)
        )
    }

    private func currentDisplayGeometries() -> (
        available: [SessionDisplayGeometry],
        fallback: SessionDisplayGeometry?
    ) {
        let available = NSScreen.screens.map { screen in
            SessionDisplayGeometry(
                displayID: screen.cmuxDisplayID,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame
            )
        }
        let fallback = (NSScreen.main ?? NSScreen.screens.first).map { screen in
            SessionDisplayGeometry(
                displayID: screen.cmuxDisplayID,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame
            )
        }
        return (available, fallback)
    }

    private func attemptStartupSessionRestoreIfNeeded(primaryWindow: NSWindow) {
        guard !didAttemptStartupSessionRestore else { return }
        didAttemptStartupSessionRestore = true
        guard !didHandleExplicitOpenIntentAtStartup else { return }
        guard let primaryContext = contextForMainTerminalWindow(primaryWindow) else { return }

        let startupSnapshot = startupSessionSnapshot
        let primaryWindowSnapshot = startupSnapshot?.windows.first
        if let primaryWindowSnapshot {
            isApplyingStartupSessionRestore = true
#if DEBUG
            dlog(
                "session.restore.start windows=\(startupSnapshot?.windows.count ?? 0) " +
                    "primaryFrame={\(debugSessionRectDescription(primaryWindowSnapshot.frame))} " +
                    "primaryDisplay={\(debugSessionDisplayDescription(primaryWindowSnapshot.display))}"
            )
#endif
            applySessionWindowSnapshot(
                primaryWindowSnapshot,
                to: primaryContext,
                window: primaryWindow
            )
        } else {
            let displays = currentDisplayGeometries()
            let fallbackGeometry = persistedWindowGeometry()
            if let restoredFrame = Self.resolvedStartupPrimaryWindowFrame(
                primarySnapshot: nil,
                fallbackFrame: fallbackGeometry?.frame,
                fallbackDisplaySnapshot: fallbackGeometry?.display,
                availableDisplays: displays.available,
                fallbackDisplay: displays.fallback
            ) {
                primaryWindow.setFrame(restoredFrame, display: true)
            }
        }

        if let startupSnapshot {
            let additionalWindows = Array(startupSnapshot
                .windows
                .dropFirst()
                .prefix(max(0, SessionPersistencePolicy.maxWindowsPerSnapshot - 1)))
#if DEBUG
            for (index, windowSnapshot) in additionalWindows.enumerated() {
                dlog(
                    "session.restore.enqueueAdditional idx=\(index + 1) " +
                        "frame={\(debugSessionRectDescription(windowSnapshot.frame))} " +
                        "display={\(debugSessionDisplayDescription(windowSnapshot.display))}"
                )
            }
#endif
            if !additionalWindows.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    for windowSnapshot in additionalWindows {
                        _ = self.createMainWindow(sessionWindowSnapshot: windowSnapshot)
                    }
                    self.completeStartupSessionRestore()
                }
            } else {
                completeStartupSessionRestore()
            }
        }
    }

    private func completeStartupSessionRestore() {
        startupSessionSnapshot = nil
        isApplyingStartupSessionRestore = false
        _ = saveSessionSnapshot(includeScrollback: false)
    }

    private func applySessionWindowSnapshot(
        _ snapshot: SessionWindowSnapshot,
        to context: MainWindowContext,
        window: NSWindow?
    ) {
#if DEBUG
        dlog(
            "session.restore.apply window=\(context.windowId.uuidString.prefix(8)) " +
                "liveWin=\(window?.windowNumber ?? -1) " +
                "snapshotFrame={\(debugSessionRectDescription(snapshot.frame))} " +
                "snapshotDisplay={\(debugSessionDisplayDescription(snapshot.display))}"
        )
#endif
        context.tabManager.restoreSessionSnapshot(snapshot.tabManager)
        context.sidebarState.isVisible = snapshot.sidebar.isVisible
        context.sidebarState.persistedWidth = CGFloat(
            SessionPersistencePolicy.sanitizedSidebarWidth(snapshot.sidebar.width)
        )
        context.sidebarSelectionState.selection = snapshot.sidebar.selection.sidebarSelection

        if let restoredFrame = resolvedWindowFrame(from: snapshot), let window {
            window.setFrame(restoredFrame, display: true)
#if DEBUG
            dlog(
                "session.restore.frameApplied window=\(context.windowId.uuidString.prefix(8)) " +
                    "applied={\(debugNSRectDescription(window.frame))}"
            )
#endif
        }
    }

    private func resolvedWindowFrame(from snapshot: SessionWindowSnapshot?) -> NSRect? {
        let displays = currentDisplayGeometries()
        return Self.resolvedWindowFrame(
            from: snapshot?.frame,
            display: snapshot?.display,
            availableDisplays: displays.available,
            fallbackDisplay: displays.fallback
        )
    }

    nonisolated static func resolvedStartupPrimaryWindowFrame(
        primarySnapshot: SessionWindowSnapshot?,
        fallbackFrame: SessionRectSnapshot?,
        fallbackDisplaySnapshot: SessionDisplaySnapshot?,
        availableDisplays: [SessionDisplayGeometry],
        fallbackDisplay: SessionDisplayGeometry?
    ) -> CGRect? {
        if let primary = resolvedWindowFrame(
            from: primarySnapshot?.frame,
            display: primarySnapshot?.display,
            availableDisplays: availableDisplays,
            fallbackDisplay: fallbackDisplay
        ) {
            return primary
        }

        return resolvedWindowFrame(
            from: fallbackFrame,
            display: fallbackDisplaySnapshot,
            availableDisplays: availableDisplays,
            fallbackDisplay: fallbackDisplay
        )
    }

    nonisolated static func resolvedWindowFrame(
        from frameSnapshot: SessionRectSnapshot?,
        display displaySnapshot: SessionDisplaySnapshot?,
        availableDisplays: [SessionDisplayGeometry],
        fallbackDisplay: SessionDisplayGeometry?
    ) -> CGRect? {
        guard let frameSnapshot else { return nil }
        let frame = frameSnapshot.cgRect
        guard frame.width.isFinite,
              frame.height.isFinite,
              frame.origin.x.isFinite,
              frame.origin.y.isFinite else {
            return nil
        }

        let minWidth = CGFloat(SessionPersistencePolicy.minimumWindowWidth)
        let minHeight = CGFloat(SessionPersistencePolicy.minimumWindowHeight)
        guard frame.width >= minWidth,
              frame.height >= minHeight else {
            return nil
        }

        guard !availableDisplays.isEmpty else { return frame }

        if let targetDisplay = display(for: displaySnapshot, in: availableDisplays) {
            if shouldPreserveExactFrame(
                frame: frame,
                displaySnapshot: displaySnapshot,
                targetDisplay: targetDisplay
            ) {
                return frame
            }
            return resolvedWindowFrame(
                frame: frame,
                displaySnapshot: displaySnapshot,
                targetDisplay: targetDisplay,
                minWidth: minWidth,
                minHeight: minHeight
            )
        }

        if let intersectingDisplay = availableDisplays.first(where: { $0.visibleFrame.intersects(frame) }) {
            return clampFrame(
                frame,
                within: intersectingDisplay.visibleFrame,
                minWidth: minWidth,
                minHeight: minHeight
            )
        }

        guard let fallbackDisplay else { return frame }
        if let sourceReference = displaySnapshot?.visibleFrame?.cgRect ?? displaySnapshot?.frame?.cgRect {
            return remappedFrame(
                frame,
                from: sourceReference,
                to: fallbackDisplay.visibleFrame,
                minWidth: minWidth,
                minHeight: minHeight
            )
        }

        return centeredFrame(
            frame,
            in: fallbackDisplay.visibleFrame,
            minWidth: minWidth,
            minHeight: minHeight
        )
    }

    private nonisolated static func resolvedWindowFrame(
        frame: CGRect,
        displaySnapshot: SessionDisplaySnapshot?,
        targetDisplay: SessionDisplayGeometry,
        minWidth: CGFloat,
        minHeight: CGFloat
    ) -> CGRect {
        if targetDisplay.visibleFrame.intersects(frame) {
            // Preserve the user's exact frame when enough of the top of the window
            // remains reachable on-screen; only clamp when the saved frame would
            // reopen with an inaccessible titlebar/top strip.
            if shouldPreserveAccessibleFrame(
                frame: frame,
                targetDisplay: targetDisplay
            ) {
                return frame
            }
            return clampFrame(
                frame,
                within: targetDisplay.visibleFrame,
                minWidth: minWidth,
                minHeight: minHeight
            )
        }

        if let sourceReference = displaySnapshot?.visibleFrame?.cgRect ?? displaySnapshot?.frame?.cgRect {
            return remappedFrame(
                frame,
                from: sourceReference,
                to: targetDisplay.visibleFrame,
                minWidth: minWidth,
                minHeight: minHeight
            )
        }

        return centeredFrame(
            frame,
            in: targetDisplay.visibleFrame,
            minWidth: minWidth,
            minHeight: minHeight
        )
    }

    private nonisolated static func shouldPreserveAccessibleFrame(
        frame: CGRect,
        targetDisplay: SessionDisplayGeometry,
        minimumVisibleTopStripWidth: CGFloat = 120,
        topStripHeight: CGFloat = 64,
        minimumVisibleTopStripHeight: CGFloat = 24
    ) -> Bool {
        let standardizedFrame = frame.standardized
        guard standardizedFrame.width.isFinite,
              standardizedFrame.height.isFinite,
              standardizedFrame.width > 0,
              standardizedFrame.height > 0,
              standardizedFrame.intersects(targetDisplay.frame) else {
            return false
        }

        let stripHeight = min(topStripHeight, standardizedFrame.height)
        let topStrip = CGRect(
            x: standardizedFrame.minX,
            y: standardizedFrame.maxY - stripHeight,
            width: standardizedFrame.width,
            height: stripHeight
        )
        let visibleTopStrip = topStrip.intersection(targetDisplay.visibleFrame)
        guard !visibleTopStrip.isNull else { return false }

        let requiredWidth = min(minimumVisibleTopStripWidth, standardizedFrame.width)
        let requiredHeight = min(minimumVisibleTopStripHeight, stripHeight)
        return visibleTopStrip.width >= requiredWidth
            && visibleTopStrip.height >= requiredHeight
    }

    private nonisolated static func display(
        for snapshot: SessionDisplaySnapshot?,
        in displays: [SessionDisplayGeometry]
    ) -> SessionDisplayGeometry? {
        guard let snapshot else { return nil }
        if let displayID = snapshot.displayID,
           let exact = displays.first(where: { $0.displayID == displayID }) {
            return exact
        }

        guard let referenceRect = (snapshot.visibleFrame ?? snapshot.frame)?.cgRect else {
            return nil
        }

        let overlaps = displays.map { display -> (display: SessionDisplayGeometry, area: CGFloat) in
            (display, intersectionArea(referenceRect, display.visibleFrame))
        }
        if let bestOverlap = overlaps.max(by: { $0.area < $1.area }), bestOverlap.area > 0 {
            return bestOverlap.display
        }

        let referenceCenter = CGPoint(x: referenceRect.midX, y: referenceRect.midY)
        return displays.min { lhs, rhs in
            let lhsDistance = distanceSquared(lhs.visibleFrame, referenceCenter)
            let rhsDistance = distanceSquared(rhs.visibleFrame, referenceCenter)
            return lhsDistance < rhsDistance
        }
    }

    private nonisolated static func remappedFrame(
        _ frame: CGRect,
        from sourceRect: CGRect,
        to targetRect: CGRect,
        minWidth: CGFloat,
        minHeight: CGFloat
    ) -> CGRect {
        let source = sourceRect.standardized
        let target = targetRect.standardized
        guard source.width.isFinite,
              source.height.isFinite,
              source.width > 1,
              source.height > 1,
              target.width.isFinite,
              target.height.isFinite,
              target.width > 0,
              target.height > 0 else {
            return centeredFrame(frame, in: targetRect, minWidth: minWidth, minHeight: minHeight)
        }

        let relativeX = (frame.minX - source.minX) / source.width
        let relativeY = (frame.minY - source.minY) / source.height
        let relativeWidth = frame.width / source.width
        let relativeHeight = frame.height / source.height

        let remapped = CGRect(
            x: target.minX + (relativeX * target.width),
            y: target.minY + (relativeY * target.height),
            width: target.width * relativeWidth,
            height: target.height * relativeHeight
        )
        return clampFrame(remapped, within: target, minWidth: minWidth, minHeight: minHeight)
    }

    private nonisolated static func centeredFrame(
        _ frame: CGRect,
        in visibleFrame: CGRect,
        minWidth: CGFloat,
        minHeight: CGFloat
    ) -> CGRect {
        let centered = CGRect(
            x: visibleFrame.midX - (frame.width / 2),
            y: visibleFrame.midY - (frame.height / 2),
            width: frame.width,
            height: frame.height
        )
        return clampFrame(centered, within: visibleFrame, minWidth: minWidth, minHeight: minHeight)
    }

    private nonisolated static func clampFrame(
        _ frame: CGRect,
        within visibleFrame: CGRect,
        minWidth: CGFloat,
        minHeight: CGFloat
    ) -> CGRect {
        guard visibleFrame.width.isFinite,
              visibleFrame.height.isFinite,
              visibleFrame.width > 0,
              visibleFrame.height > 0 else {
            return frame
        }

        let maxWidth = max(visibleFrame.width, 1)
        let maxHeight = max(visibleFrame.height, 1)
        let widthFloor = min(minWidth, maxWidth)
        let heightFloor = min(minHeight, maxHeight)

        let width = min(max(frame.width, widthFloor), maxWidth)
        let height = min(max(frame.height, heightFloor), maxHeight)
        let maxX = visibleFrame.maxX - width
        let maxY = visibleFrame.maxY - height
        let x = min(max(frame.minX, visibleFrame.minX), maxX)
        let y = min(max(frame.minY, visibleFrame.minY), maxY)

        return CGRect(x: x, y: y, width: width, height: height)
    }

    private nonisolated static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return max(0, intersection.width) * max(0, intersection.height)
    }

    private nonisolated static func distanceSquared(_ rect: CGRect, _ point: CGPoint) -> CGFloat {
        let dx = rect.midX - point.x
        let dy = rect.midY - point.y
        return (dx * dx) + (dy * dy)
    }

    private nonisolated static func shouldPreserveExactFrame(
        frame: CGRect,
        displaySnapshot: SessionDisplaySnapshot?,
        targetDisplay: SessionDisplayGeometry
    ) -> Bool {
        guard let displaySnapshot else { return false }
        guard let snapshotDisplayID = displaySnapshot.displayID,
              let targetDisplayID = targetDisplay.displayID,
              snapshotDisplayID == targetDisplayID else {
            return false
        }

        let visibleMatches = displaySnapshot.visibleFrame.map {
            rectApproximatelyEqual($0.cgRect, targetDisplay.visibleFrame)
        } ?? false
        let frameMatches = displaySnapshot.frame.map {
            rectApproximatelyEqual($0.cgRect, targetDisplay.frame)
        } ?? false
        guard visibleMatches || frameMatches else { return false }

        return frame.width.isFinite
            && frame.height.isFinite
            && frame.origin.x.isFinite
            && frame.origin.y.isFinite
    }

    private nonisolated static func rectApproximatelyEqual(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat = 1
    ) -> Bool {
        let lhsStd = lhs.standardized
        let rhsStd = rhs.standardized
        return abs(lhsStd.origin.x - rhsStd.origin.x) <= tolerance
            && abs(lhsStd.origin.y - rhsStd.origin.y) <= tolerance
            && abs(lhsStd.size.width - rhsStd.size.width) <= tolerance
            && abs(lhsStd.size.height - rhsStd.size.height) <= tolerance
    }

    private func displaySnapshot(for window: NSWindow?) -> SessionDisplaySnapshot? {
        guard let window else { return nil }
        let screen = window.screen
            ?? NSScreen.screens.first(where: { $0.frame.intersects(window.frame) })
        guard let screen else { return nil }

        return SessionDisplaySnapshot(
            displayID: screen.cmuxDisplayID,
            frame: SessionRectSnapshot(screen.frame),
            visibleFrame: SessionRectSnapshot(screen.visibleFrame)
        )
    }

    private func startSessionAutosaveTimerIfNeeded() {
        guard sessionAutosaveTimer == nil else { return }
        let env = ProcessInfo.processInfo.environment
        guard !isRunningUnderXCTest(env) else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        let interval = SessionPersistencePolicy.autosaveInterval
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self,
                  Self.shouldRunSessionAutosaveTick(isTerminatingApp: self.isTerminatingApp) else {
                return
            }
            self.runSessionAutosaveTick(source: "timer")
        }
        sessionAutosaveTimer = timer
        timer.resume()
    }

    private func stopSessionAutosaveTimer() {
        sessionAutosaveTimer?.cancel()
        sessionAutosaveTimer = nil
        sessionAutosaveTickInFlight = false
        sessionAutosaveDeferredRetryPending = false
    }

    private func installLifecycleSnapshotObserversIfNeeded() {
        guard !didInstallLifecycleSnapshotObservers else { return }
        didInstallLifecycleSnapshotObservers = true

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let powerOffObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isTerminatingApp = true
                _ = self.saveSessionSnapshot(includeScrollback: true, removeWhenEmpty: false)
            }
        }
        lifecycleSnapshotObservers.append(powerOffObserver)

        let sessionResignObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isTerminatingApp {
                    _ = self.saveSessionSnapshot(includeScrollback: true, removeWhenEmpty: false)
                } else {
                    _ = self.saveSessionSnapshot(includeScrollback: false)
                }
            }
        }
        lifecycleSnapshotObservers.append(sessionResignObserver)

        let didWakeObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.restartSocketListenerIfEnabled(source: "workspace.didWake")
            }
        }
        lifecycleSnapshotObservers.append(didWakeObserver)
    }

    private func socketListenerConfigurationIfEnabled() -> (mode: SocketControlMode, path: String)? {
        let raw = UserDefaults.standard.string(forKey: SocketControlSettings.appStorageKey)
            ?? SocketControlSettings.defaultMode.rawValue
        let userMode = SocketControlSettings.migrateMode(raw)
        let mode = SocketControlSettings.effectiveMode(userMode: userMode)
        guard mode != .off else { return nil }
        return (mode: mode, path: SocketControlSettings.socketPath())
    }

    private func restartSocketListenerIfEnabled(source: String) {
        guard let tabManager,
              let config = socketListenerConfigurationIfEnabled() else { return }
        let restartPath = TerminalController.shared.activeSocketPath(preferredPath: config.path)
        sentryBreadcrumb("socket.listener.restart", category: "socket", data: [
            "mode": config.mode.rawValue,
            "path": restartPath,
            "source": source
        ])
        TerminalController.shared.stop()
        TerminalController.shared.start(tabManager: tabManager, socketPath: restartPath, accessMode: config.mode)
    }

    private func disableSuddenTerminationIfNeeded() {
        guard !didDisableSuddenTermination else { return }
        ProcessInfo.processInfo.disableSuddenTermination()
        didDisableSuddenTermination = true
    }

    private func enableSuddenTerminationIfNeeded() {
        guard didDisableSuddenTermination else { return }
        ProcessInfo.processInfo.enableSuddenTermination()
        didDisableSuddenTermination = false
    }

    private func sessionAutosaveFingerprint(includeScrollback: Bool) -> Int? {
        guard !includeScrollback else { return nil }

        var hasher = Hasher()
        let contexts = mainWindowContexts.values.sorted { lhs, rhs in
            lhs.windowId.uuidString < rhs.windowId.uuidString
        }
        hasher.combine(contexts.count)

        for context in contexts.prefix(SessionPersistencePolicy.maxWindowsPerSnapshot) {
            hasher.combine(context.windowId)
            hasher.combine(context.tabManager.sessionAutosaveFingerprint())
            hasher.combine(context.sidebarState.isVisible)
            hasher.combine(
                Int(SessionPersistencePolicy.sanitizedSidebarWidth(Double(context.sidebarState.persistedWidth)).rounded())
            )

            switch context.sidebarSelectionState.selection {
            case .tabs:
                hasher.combine(0)
            case .notifications:
                hasher.combine(1)
            }

            if let window = context.window ?? windowForMainWindowId(context.windowId) {
                Self.hashFrame(window.frame, into: &hasher)
            } else {
                hasher.combine(-1)
            }
        }

        return hasher.finalize()
    }

    @discardableResult
    private func saveSessionSnapshot(includeScrollback: Bool, removeWhenEmpty: Bool = false) -> Bool {
        if Self.shouldSkipSessionSaveDuringStartupRestore(
            isApplyingStartupSessionRestore: isApplyingStartupSessionRestore,
            includeScrollback: includeScrollback
        ) {
#if DEBUG
            dlog("session.save.skipped reason=startup_restore_in_progress includeScrollback=0")
#endif
            return false
        }

        let writeSynchronously = Self.shouldWriteSessionSnapshotSynchronously(
            isTerminatingApp: isTerminatingApp,
            includeScrollback: includeScrollback
        )
#if DEBUG
        let timingStart = CmuxTypingTiming.start()
        defer {
            CmuxTypingTiming.logDuration(
                path: "session.saveSnapshot",
                startedAt: timingStart,
                extra: "includeScrollback=\(includeScrollback ? 1 : 0) removeWhenEmpty=\(removeWhenEmpty ? 1 : 0) sync=\(writeSynchronously ? 1 : 0)"
            )
        }
#endif

        guard let snapshot = buildSessionSnapshot(includeScrollback: includeScrollback) else {
            persistSessionSnapshot(
                nil,
                removeWhenEmpty: removeWhenEmpty,
                persistedGeometryData: nil,
                synchronously: writeSynchronously
            )
            return false
        }

        let persistedGeometryData = snapshot.windows.first.flatMap { primaryWindow in
            Self.encodedPersistedWindowGeometryData(
                frame: primaryWindow.frame,
                display: primaryWindow.display
            )
        }

#if DEBUG
        debugLogSessionSaveSnapshot(snapshot, includeScrollback: includeScrollback)
#endif
        persistSessionSnapshot(
            snapshot,
            removeWhenEmpty: false,
            persistedGeometryData: persistedGeometryData,
            synchronously: writeSynchronously
        )
        return true
    }

    nonisolated static func shouldPersistSnapshotOnWindowUnregister(isTerminatingApp: Bool) -> Bool {
        !isTerminatingApp
    }

    nonisolated static func shouldRemoveSnapshotWhenNoWindowsRemainOnWindowUnregister(
        isTerminatingApp: Bool
    ) -> Bool {
        !isTerminatingApp
    }

    nonisolated static func shouldSkipSessionSaveDuringStartupRestore(
        isApplyingStartupSessionRestore: Bool,
        includeScrollback: Bool
    ) -> Bool {
        isApplyingStartupSessionRestore && !includeScrollback
    }

    nonisolated static func shouldRunSessionAutosaveTick(isTerminatingApp: Bool) -> Bool {
        !isTerminatingApp
    }

    private func remainingSessionAutosaveTypingQuietPeriod(
        nowUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> TimeInterval? {
        guard lastTypingActivityAt > 0 else { return nil }
        let elapsed = nowUptime - lastTypingActivityAt
        guard elapsed < Self.sessionAutosaveTypingQuietPeriod else { return nil }
        return Self.sessionAutosaveTypingQuietPeriod - elapsed
    }

    private func scheduleDeferredSessionAutosaveRetry(after delay: TimeInterval) {
        guard delay.isFinite, delay > 0 else { return }
        guard !sessionAutosaveDeferredRetryPending else { return }
        sessionAutosaveDeferredRetryPending = true
        sessionPersistenceQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sessionAutosaveDeferredRetryPending = false
                self.runSessionAutosaveTick(source: "typingQuietRetry")
            }
        }
    }

    private func runSessionAutosaveTick(source: String) {
        guard Self.shouldRunSessionAutosaveTick(isTerminatingApp: isTerminatingApp) else { return }
        guard !sessionAutosaveTickInFlight else { return }
        if let remainingQuietPeriod = remainingSessionAutosaveTypingQuietPeriod() {
#if DEBUG
            dlog(
                "session.save.skipped reason=typing_recent includeScrollback=0 source=\(source) " +
                "retryMs=\(Int((remainingQuietPeriod * 1000).rounded()))"
            )
#endif
            scheduleDeferredSessionAutosaveRetry(after: remainingQuietPeriod)
            return
        }

        sessionAutosaveTickInFlight = true
#if DEBUG
        let timingStart = CmuxTypingTiming.start()
        let phaseStart = ProcessInfo.processInfo.systemUptime
        var fingerprintMs: Double = 0
        var saveMs: Double = 0
        defer {
            sessionAutosaveTickInFlight = false
            let totalMs = (ProcessInfo.processInfo.systemUptime - phaseStart) * 1000.0
            CmuxTypingTiming.logBreakdown(
                path: "session.autosaveTick.phase",
                totalMs: totalMs,
                thresholdMs: 2.0,
                parts: [
                    ("fingerprintMs", fingerprintMs),
                    ("saveMs", saveMs),
                ],
                extra: "source=\(source)"
            )
            CmuxTypingTiming.logDuration(
                path: "session.autosaveTick",
                startedAt: timingStart,
                extra: "source=\(source)"
            )
        }
#else
        defer { sessionAutosaveTickInFlight = false }
#endif

        let now = Date()
#if DEBUG
        let fingerprintStart = ProcessInfo.processInfo.systemUptime
#endif
        let autosaveFingerprint = sessionAutosaveFingerprint(includeScrollback: false)
#if DEBUG
        fingerprintMs = (ProcessInfo.processInfo.systemUptime - fingerprintStart) * 1000.0
#endif
        if Self.shouldSkipSessionAutosaveForUnchangedFingerprint(
            isTerminatingApp: isTerminatingApp,
            includeScrollback: false,
            previousFingerprint: lastSessionAutosaveFingerprint,
            currentFingerprint: autosaveFingerprint,
            lastPersistedAt: lastSessionAutosavePersistedAt,
            now: now
        ) {
#if DEBUG
            dlog(
                "session.save.skipped reason=unchanged_autosave_fingerprint includeScrollback=0 source=\(source)"
            )
#endif
            return
        }

#if DEBUG
        let saveStart = ProcessInfo.processInfo.systemUptime
#endif
        _ = saveSessionSnapshot(includeScrollback: false)
#if DEBUG
        saveMs = (ProcessInfo.processInfo.systemUptime - saveStart) * 1000.0
#endif
        updateSessionAutosaveSaveState(
            includeScrollback: false,
            persistedAt: now,
            fingerprint: autosaveFingerprint
        )
    }

    fileprivate func recordTypingActivity() {
        lastTypingActivityAt = ProcessInfo.processInfo.systemUptime
    }

    nonisolated static func shouldWriteSessionSnapshotSynchronously(
        isTerminatingApp: Bool,
        includeScrollback: Bool
    ) -> Bool {
        isTerminatingApp && includeScrollback
    }

    nonisolated static func shouldSkipSessionAutosaveForUnchangedFingerprint(
        isTerminatingApp: Bool,
        includeScrollback: Bool,
        previousFingerprint: Int?,
        currentFingerprint: Int?,
        lastPersistedAt: Date,
        now: Date,
        maximumAutosaveSkippableInterval: TimeInterval = 60
    ) -> Bool {
        guard !isTerminatingApp,
              !includeScrollback,
              let previousFingerprint,
              let currentFingerprint,
              previousFingerprint == currentFingerprint else {
            return false
        }

        return now.timeIntervalSince(lastPersistedAt) < maximumAutosaveSkippableInterval
    }

    private func updateSessionAutosaveSaveState(
        includeScrollback: Bool,
        persistedAt: Date,
        fingerprint: Int?
    ) {
        guard !isTerminatingApp, !includeScrollback else { return }
        lastSessionAutosaveFingerprint = fingerprint
        lastSessionAutosavePersistedAt = persistedAt
    }

    private nonisolated static func hashFrame(_ frame: NSRect, into hasher: inout Hasher) {
        let standardized = frame.standardized
        let quantized = [
            standardized.origin.x,
            standardized.origin.y,
            standardized.size.width,
            standardized.size.height,
        ].map { Int(($0 * 2).rounded()) }
        quantized.forEach { hasher.combine($0) }
    }

    private func persistSessionSnapshot(
        _ snapshot: AppSessionSnapshot?,
        removeWhenEmpty: Bool,
        persistedGeometryData: Data?,
        synchronously: Bool
    ) {
        guard snapshot != nil || removeWhenEmpty || persistedGeometryData != nil else { return }

        let writeBlock = {
            Self.removeLegacyPersistedWindowGeometry()
            if let persistedGeometryData {
                UserDefaults.standard.set(
                    persistedGeometryData,
                    forKey: Self.persistedWindowGeometryDefaultsKey
                )
            }
            if let snapshot {
                _ = SessionPersistenceStore.save(snapshot)
            } else if removeWhenEmpty {
                SessionPersistenceStore.removeSnapshot()
            }
        }

        if synchronously {
            writeBlock()
        } else {
            sessionPersistenceQueue.async(execute: writeBlock)
        }
    }

    private func buildSessionSnapshot(includeScrollback: Bool) -> AppSessionSnapshot? {
        let contexts = mainWindowContexts.values.sorted { lhs, rhs in
            let lhsWindow = lhs.window ?? windowForMainWindowId(lhs.windowId)
            let rhsWindow = rhs.window ?? windowForMainWindowId(rhs.windowId)
            let lhsIsKey = lhsWindow?.isKeyWindow ?? false
            let rhsIsKey = rhsWindow?.isKeyWindow ?? false
            if lhsIsKey != rhsIsKey {
                return lhsIsKey && !rhsIsKey
            }
            return lhs.windowId.uuidString < rhs.windowId.uuidString
        }

        guard !contexts.isEmpty else { return nil }

        let windows: [SessionWindowSnapshot] = contexts
            .prefix(SessionPersistencePolicy.maxWindowsPerSnapshot)
            .map { context in
                let window = context.window ?? windowForMainWindowId(context.windowId)
                return SessionWindowSnapshot(
                    frame: window.map { SessionRectSnapshot($0.frame) },
                    display: displaySnapshot(for: window),
                    tabManager: context.tabManager.sessionSnapshot(includeScrollback: includeScrollback),
                    sidebar: SessionSidebarSnapshot(
                        isVisible: context.sidebarState.isVisible,
                        selection: SessionSidebarSelection(selection: context.sidebarSelectionState.selection),
                        width: SessionPersistencePolicy.sanitizedSidebarWidth(Double(context.sidebarState.persistedWidth))
                    )
                )
            }

        guard !windows.isEmpty else { return nil }
        return AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: Date().timeIntervalSince1970,
            windows: windows
        )
    }

#if DEBUG
    private func debugLogSessionSaveSnapshot(
        _ snapshot: AppSessionSnapshot,
        includeScrollback: Bool
    ) {
        dlog(
            "session.save includeScrollback=\(includeScrollback ? 1 : 0) " +
                "windows=\(snapshot.windows.count)"
        )
        for (index, windowSnapshot) in snapshot.windows.enumerated() {
            let workspaceCount = windowSnapshot.tabManager.workspaces.count
            let selectedWorkspace = windowSnapshot.tabManager.selectedWorkspaceIndex.map(String.init) ?? "nil"
            dlog(
                "session.save.window idx=\(index) " +
                    "frame={\(debugSessionRectDescription(windowSnapshot.frame))} " +
                    "display={\(debugSessionDisplayDescription(windowSnapshot.display))} " +
                    "workspaces=\(workspaceCount) selected=\(selectedWorkspace)"
            )
        }
    }

    private func debugSessionRectDescription(_ rect: SessionRectSnapshot?) -> String {
        guard let rect else { return "nil" }
        return "x=\(debugSessionNumber(rect.x)) y=\(debugSessionNumber(rect.y)) " +
            "w=\(debugSessionNumber(rect.width)) h=\(debugSessionNumber(rect.height))"
    }

    private func debugNSRectDescription(_ rect: NSRect?) -> String {
        guard let rect else { return "nil" }
        return "x=\(debugSessionNumber(Double(rect.origin.x))) " +
            "y=\(debugSessionNumber(Double(rect.origin.y))) " +
            "w=\(debugSessionNumber(Double(rect.size.width))) " +
            "h=\(debugSessionNumber(Double(rect.size.height)))"
    }

    private func debugSessionDisplayDescription(_ display: SessionDisplaySnapshot?) -> String {
        guard let display else { return "nil" }
        let displayIdText = display.displayID.map(String.init) ?? "nil"
        return "id=\(displayIdText) " +
            "frame={\(debugSessionRectDescription(display.frame))} " +
            "visible={\(debugSessionRectDescription(display.visibleFrame))}"
    }

    private func debugSessionNumber(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
#endif

    private func notifyMainWindowContextsDidChange() {
        NotificationCenter.default.post(name: .mainWindowContextsDidChange, object: self)
    }

    /// Register a terminal window with the AppDelegate so menu commands and socket control
    /// can target whichever window is currently active.
    func registerMainWindow(
        _ window: NSWindow,
        windowId: UUID,
        tabManager: TabManager,
        sidebarState: SidebarState,
        sidebarSelectionState: SidebarSelectionState
    ) {
        tabManager.window = window

        let key = ObjectIdentifier(window)
        #if DEBUG
        let priorManagerToken = debugManagerToken(self.tabManager)
        #endif
        if let existing = mainWindowContexts[key] {
            existing.window = window
        } else if let existing = mainWindowContexts.values.first(where: { $0.windowId == windowId }) {
            existing.window = window
            reindexMainWindowContextIfNeeded(existing, for: window)
        } else {
            mainWindowContexts[key] = MainWindowContext(
                windowId: windowId,
                tabManager: tabManager,
                sidebarState: sidebarState,
                sidebarSelectionState: sidebarSelectionState,
                window: window
            )
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] note in
                guard let self, let closing = note.object as? NSWindow else { return }
                self.unregisterMainWindow(closing)
            }
        }
        commandPaletteVisibilityByWindowId[windowId] = false
        commandPaletteSelectionByWindowId[windowId] = 0
        commandPaletteSnapshotByWindowId[windowId] = .empty

#if DEBUG
        dlog(
            "mainWindow.register windowId=\(String(windowId.uuidString.prefix(8))) window={\(debugWindowToken(window))} manager=\(debugManagerToken(tabManager)) priorActiveMgr=\(priorManagerToken) \(debugShortcutRouteSnapshot())"
        )
#endif
        notifyMainWindowContextsDidChange()
        if window.isKeyWindow {
            setActiveMainWindow(window)
        }

        attemptStartupSessionRestoreIfNeeded(primaryWindow: window)
        if !isTerminatingApp {
            _ = saveSessionSnapshot(includeScrollback: false)
        }
    }

    struct MainWindowSummary {
        let windowId: UUID
        let isKeyWindow: Bool
        let isVisible: Bool
        let workspaceCount: Int
        let selectedWorkspaceId: UUID?
    }

    struct WindowMoveTarget: Identifiable {
        let windowId: UUID
        let label: String
        let tabManager: TabManager
        let isCurrentWindow: Bool

        var id: UUID { windowId }
    }

    struct WorkspaceMoveTarget: Identifiable {
        let windowId: UUID
        let workspaceId: UUID
        let windowLabel: String
        let workspaceTitle: String
        let tabManager: TabManager
        let isCurrentWindow: Bool

        var id: String { "\(windowId.uuidString):\(workspaceId.uuidString)" }
        var label: String {
            isCurrentWindow ? workspaceTitle : "\(workspaceTitle) (\(windowLabel))"
        }
    }

    func listMainWindowSummaries() -> [MainWindowSummary] {
        let contexts = Array(mainWindowContexts.values)
        return contexts.map { ctx in
            let window = ctx.window ?? windowForMainWindowId(ctx.windowId)
            return MainWindowSummary(
                windowId: ctx.windowId,
                isKeyWindow: window?.isKeyWindow ?? false,
                isVisible: window?.isVisible ?? false,
                workspaceCount: ctx.tabManager.tabs.count,
                selectedWorkspaceId: ctx.tabManager.selectedTabId
            )
        }
    }

    func windowMoveTargets(referenceWindowId: UUID?) -> [WindowMoveTarget] {
        let orderedSummaries = orderedMainWindowSummaries(referenceWindowId: referenceWindowId)
        let labels = windowLabelsById(orderedSummaries: orderedSummaries, referenceWindowId: referenceWindowId)
        return orderedSummaries.compactMap { summary in
            guard let manager = tabManagerFor(windowId: summary.windowId) else { return nil }
            let label = labels[summary.windowId] ?? "Window"
            return WindowMoveTarget(
                windowId: summary.windowId,
                label: label,
                tabManager: manager,
                isCurrentWindow: summary.windowId == referenceWindowId
            )
        }
    }

    func workspaceMoveTargets(excludingWorkspaceId: UUID? = nil, referenceWindowId: UUID?) -> [WorkspaceMoveTarget] {
        let orderedSummaries = orderedMainWindowSummaries(referenceWindowId: referenceWindowId)
        let labels = windowLabelsById(orderedSummaries: orderedSummaries, referenceWindowId: referenceWindowId)

        var targets: [WorkspaceMoveTarget] = []
        targets.reserveCapacity(orderedSummaries.reduce(0) { partial, summary in
            partial + summary.workspaceCount
        })

        for summary in orderedSummaries {
            guard let manager = tabManagerFor(windowId: summary.windowId) else { continue }
            let windowLabel = labels[summary.windowId] ?? "Window"
            let isCurrentWindow = summary.windowId == referenceWindowId
            for workspace in manager.tabs {
                if workspace.id == excludingWorkspaceId {
                    continue
                }
                targets.append(
                    WorkspaceMoveTarget(
                        windowId: summary.windowId,
                        workspaceId: workspace.id,
                        windowLabel: windowLabel,
                        workspaceTitle: workspaceDisplayName(workspace),
                        tabManager: manager,
                        isCurrentWindow: isCurrentWindow
                    )
                )
            }
        }

        return targets
    }

    @discardableResult
    func moveWorkspaceToWindow(workspaceId: UUID, windowId: UUID, focus: Bool = true) -> Bool {
        guard let sourceManager = tabManagerFor(tabId: workspaceId),
              let destinationManager = tabManagerFor(windowId: windowId) else {
            return false
        }

        if sourceManager === destinationManager {
            if focus {
                destinationManager.focusTab(workspaceId, suppressFlash: true)
                _ = focusMainWindow(windowId: windowId)
                TerminalController.shared.setActiveTabManager(destinationManager)
            }
            return true
        }

        guard let workspace = sourceManager.detachWorkspace(tabId: workspaceId) else { return false }
        destinationManager.attachWorkspace(workspace, select: focus)

        if focus {
            _ = focusMainWindow(windowId: windowId)
            TerminalController.shared.setActiveTabManager(destinationManager)
        }
        return true
    }

    @discardableResult
    func moveWorkspaceToNewWindow(workspaceId: UUID, focus: Bool = true) -> UUID? {
        let windowId = createMainWindow()
        guard let destinationManager = tabManagerFor(windowId: windowId) else { return nil }
        let bootstrapWorkspaceId = destinationManager.tabs.first?.id

        guard moveWorkspaceToWindow(workspaceId: workspaceId, windowId: windowId, focus: focus) else {
            _ = closeMainWindow(windowId: windowId)
            return nil
        }

        // Remove the bootstrap workspace from the new window once the moved workspace arrives.
        if let bootstrapWorkspaceId,
           bootstrapWorkspaceId != workspaceId,
           let bootstrapWorkspace = destinationManager.tabs.first(where: { $0.id == bootstrapWorkspaceId }),
           destinationManager.tabs.count > 1 {
            destinationManager.closeWorkspace(bootstrapWorkspace)
        }
        return windowId
    }

    func locateBonsplitSurface(tabId: UUID) -> (windowId: UUID, workspaceId: UUID, panelId: UUID, tabManager: TabManager)? {
        let bonsplitTabId = TabID(uuid: tabId)
        for context in mainWindowContexts.values {
            for workspace in context.tabManager.tabs {
                if let panelId = workspace.panelIdFromSurfaceId(bonsplitTabId) {
                    return (context.windowId, workspace.id, panelId, context.tabManager)
                }
            }
        }
        return nil
    }

    @discardableResult
    func moveSurface(
        panelId: UUID,
        toWorkspace targetWorkspaceId: UUID,
        targetPane: PaneID? = nil,
        targetIndex: Int? = nil,
        splitTarget: (orientation: SplitOrientation, insertFirst: Bool)? = nil,
        focus: Bool = true,
        focusWindow: Bool = true
    ) -> Bool {
#if DEBUG
        let moveStart = ProcessInfo.processInfo.systemUptime
        let splitLabel = splitTarget.map { split in
            "\(split.orientation.rawValue):\(split.insertFirst ? 1 : 0)"
        } ?? "none"
        func elapsedMs(since start: TimeInterval) -> String {
            let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
            return String(format: "%.2f", ms)
        }
        dlog(
            "surface.move.begin panel=\(panelId.uuidString.prefix(5)) targetWs=\(targetWorkspaceId.uuidString.prefix(5)) " +
            "targetPane=\(targetPane?.id.uuidString.prefix(5) ?? "auto") targetIndex=\(targetIndex.map(String.init) ?? "nil") " +
            "split=\(splitLabel) focus=\(focus ? 1 : 0) focusWindow=\(focusWindow ? 1 : 0)"
        )
#endif
        guard let source = locateSurface(surfaceId: panelId) else {
#if DEBUG
            dlog("surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=sourcePanelNotFound elapsedMs=\(elapsedMs(since: moveStart))")
#endif
            return false
        }
        guard let sourceWorkspace = source.tabManager.tabs.first(where: { $0.id == source.workspaceId }) else {
#if DEBUG
            dlog("surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=sourceWorkspaceMissing elapsedMs=\(elapsedMs(since: moveStart))")
#endif
            return false
        }
        guard let destinationManager = tabManagerFor(tabId: targetWorkspaceId) else {
#if DEBUG
            dlog("surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=destinationManagerMissing elapsedMs=\(elapsedMs(since: moveStart))")
#endif
            return false
        }
        guard let destinationWorkspace = destinationManager.tabs.first(where: { $0.id == targetWorkspaceId }) else {
#if DEBUG
            dlog("surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=destinationWorkspaceMissing elapsedMs=\(elapsedMs(since: moveStart))")
#endif
            return false
        }
#if DEBUG
        dlog(
            "surface.move.route panel=\(panelId.uuidString.prefix(5)) sourceWs=\(sourceWorkspace.id.uuidString.prefix(5)) " +
            "sourceWin=\(source.windowId.uuidString.prefix(5)) destinationWs=\(destinationWorkspace.id.uuidString.prefix(5)) " +
            "sameWorkspace=\(destinationWorkspace.id == sourceWorkspace.id ? 1 : 0)"
        )
#endif

        let resolvedTargetPane = targetPane.flatMap { pane in
            destinationWorkspace.bonsplitController.allPaneIds.first(where: { $0 == pane })
        } ?? destinationWorkspace.bonsplitController.focusedPaneId
            ?? destinationWorkspace.bonsplitController.allPaneIds.first

        guard let resolvedTargetPane else {
#if DEBUG
            dlog(
                "surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=targetPaneMissing " +
                "destinationWs=\(destinationWorkspace.id.uuidString.prefix(5)) elapsedMs=\(elapsedMs(since: moveStart))"
            )
#endif
            return false
        }

        if destinationWorkspace.id == sourceWorkspace.id {
            if let splitTarget {
                guard let sourceTabId = sourceWorkspace.surfaceIdFromPanelId(panelId),
                      sourceWorkspace.bonsplitController.splitPane(
                        resolvedTargetPane,
                        orientation: splitTarget.orientation,
                        movingTab: sourceTabId,
                        insertFirst: splitTarget.insertFirst
                      ) != nil else {
#if DEBUG
                    dlog(
                        "surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=sameWorkspaceSplitFailed " +
                        "targetPane=\(resolvedTargetPane.id.uuidString.prefix(5)) split=\(splitLabel) " +
                        "elapsedMs=\(elapsedMs(since: moveStart))"
                    )
#endif
                    return false
                }
                if focus {
                    source.tabManager.focusTab(sourceWorkspace.id, surfaceId: panelId, suppressFlash: true)
                }
#if DEBUG
                dlog(
                    "surface.move.end panel=\(panelId.uuidString.prefix(5)) path=sameWorkspaceSplit moved=1 " +
                    "targetPane=\(resolvedTargetPane.id.uuidString.prefix(5)) elapsedMs=\(elapsedMs(since: moveStart))"
                )
#endif
                return true
            }

            let moved = sourceWorkspace.moveSurface(
                panelId: panelId,
                toPane: resolvedTargetPane,
                atIndex: targetIndex,
                focus: focus
            )
#if DEBUG
            dlog(
                "surface.move.end panel=\(panelId.uuidString.prefix(5)) path=sameWorkspaceMove moved=\(moved ? 1 : 0) " +
                "targetPane=\(resolvedTargetPane.id.uuidString.prefix(5)) targetIndex=\(targetIndex.map(String.init) ?? "nil") " +
                "elapsedMs=\(elapsedMs(since: moveStart))"
            )
#endif
            return moved
        }

        let sourcePane = sourceWorkspace.paneId(forPanelId: panelId)
        let sourceIndex = sourceWorkspace.indexInPane(forPanelId: panelId)
#if DEBUG
        let detachStart = ProcessInfo.processInfo.systemUptime
#endif

        guard let detached = sourceWorkspace.detachSurface(panelId: panelId) else {
#if DEBUG
            dlog(
                "surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=detachFailed " +
                "elapsedMs=\(elapsedMs(since: moveStart))"
            )
#endif
            return false
        }
#if DEBUG
        let detachMs = elapsedMs(since: detachStart)
        let attachStart = ProcessInfo.processInfo.systemUptime
#endif
        guard destinationWorkspace.attachDetachedSurface(
            detached,
            inPane: resolvedTargetPane,
            atIndex: targetIndex,
            focus: focus
        ) != nil else {
            rollbackDetachedSurface(
                detached,
                to: sourceWorkspace,
                sourcePane: sourcePane,
                sourceIndex: sourceIndex,
                focus: focus
            )
#if DEBUG
            dlog(
                "surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=attachFailed " +
                "detachMs=\(detachMs) elapsedMs=\(elapsedMs(since: moveStart))"
            )
#endif
            return false
        }
#if DEBUG
        let attachMs = elapsedMs(since: attachStart)
        var splitMs = "0.00"
#endif

        if let splitTarget {
#if DEBUG
            let splitStart = ProcessInfo.processInfo.systemUptime
#endif
            guard let movedTabId = destinationWorkspace.surfaceIdFromPanelId(panelId),
                  destinationWorkspace.bonsplitController.splitPane(
                    resolvedTargetPane,
                    orientation: splitTarget.orientation,
                    movingTab: movedTabId,
                    insertFirst: splitTarget.insertFirst
                  ) != nil else {
                if let detachedFromDestination = destinationWorkspace.detachSurface(panelId: panelId) {
                    rollbackDetachedSurface(
                        detachedFromDestination,
                        to: sourceWorkspace,
                        sourcePane: sourcePane,
                        sourceIndex: sourceIndex,
                        focus: focus
                    )
                }
#if DEBUG
                dlog(
                    "surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=postAttachSplitFailed " +
                    "detachMs=\(detachMs) attachMs=\(attachMs) elapsedMs=\(elapsedMs(since: moveStart))"
                )
#endif
                return false
            }
#if DEBUG
            splitMs = elapsedMs(since: splitStart)
#endif
        }

#if DEBUG
        let cleanupStart = ProcessInfo.processInfo.systemUptime
#endif
        cleanupEmptySourceWorkspaceAfterSurfaceMove(
            sourceWorkspace: sourceWorkspace,
            sourceManager: source.tabManager,
            sourceWindowId: source.windowId
        )
#if DEBUG
        let cleanupMs = elapsedMs(since: cleanupStart)
        let focusStart = ProcessInfo.processInfo.systemUptime
#endif

        if focus {
            let destinationWindowId = focusWindow ? windowId(for: destinationManager) : nil
            if let destinationWindowId {
                _ = focusMainWindow(windowId: destinationWindowId)
            }
            destinationManager.focusTab(targetWorkspaceId, surfaceId: panelId, suppressFlash: true)
            if let destinationWindowId {
                reassertCrossWindowSurfaceMoveFocusIfNeeded(
                    destinationWindowId: destinationWindowId,
                    sourceWindowId: source.windowId,
                    destinationWorkspaceId: targetWorkspaceId,
                    destinationPanelId: panelId,
                    destinationManager: destinationManager
                )
            }
        }
#if DEBUG
        let focusMs = elapsedMs(since: focusStart)
        dlog(
            "surface.move.end panel=\(panelId.uuidString.prefix(5)) path=crossWorkspace moved=1 " +
            "sourceWs=\(sourceWorkspace.id.uuidString.prefix(5)) destinationWs=\(destinationWorkspace.id.uuidString.prefix(5)) " +
            "targetPane=\(resolvedTargetPane.id.uuidString.prefix(5)) targetIndex=\(targetIndex.map(String.init) ?? "nil") " +
            "split=\(splitLabel) detachMs=\(detachMs) attachMs=\(attachMs) splitMs=\(splitMs) " +
            "cleanupMs=\(cleanupMs) focusMs=\(focusMs) elapsedMs=\(elapsedMs(since: moveStart))"
        )
#endif

        return true
    }

    @discardableResult
    func moveBonsplitTab(
        tabId: UUID,
        toWorkspace targetWorkspaceId: UUID,
        targetPane: PaneID? = nil,
        targetIndex: Int? = nil,
        splitTarget: (orientation: SplitOrientation, insertFirst: Bool)? = nil,
        focus: Bool = true,
        focusWindow: Bool = true
    ) -> Bool {
#if DEBUG
        let moveStart = ProcessInfo.processInfo.systemUptime
        func elapsedMs(since start: TimeInterval) -> String {
            let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
            return String(format: "%.2f", ms)
        }
        dlog(
            "surface.moveBonsplit.begin tab=\(tabId.uuidString.prefix(5)) targetWs=\(targetWorkspaceId.uuidString.prefix(5)) " +
            "targetPane=\(targetPane?.id.uuidString.prefix(5) ?? "auto") targetIndex=\(targetIndex.map(String.init) ?? "nil")"
        )
#endif
        guard let located = locateBonsplitSurface(tabId: tabId) else {
#if DEBUG
            dlog(
                "surface.moveBonsplit.fail tab=\(tabId.uuidString.prefix(5)) reason=tabNotFound " +
                "targetWs=\(targetWorkspaceId.uuidString.prefix(5)) elapsedMs=\(elapsedMs(since: moveStart))"
            )
#endif
            return false
        }
#if DEBUG
        dlog(
            "surface.moveBonsplit.located tab=\(tabId.uuidString.prefix(5)) panel=\(located.panelId.uuidString.prefix(5)) " +
            "sourceWs=\(located.workspaceId.uuidString.prefix(5)) sourceWin=\(located.windowId.uuidString.prefix(5))"
        )
#endif
        let moved = moveSurface(
            panelId: located.panelId,
            toWorkspace: targetWorkspaceId,
            targetPane: targetPane,
            targetIndex: targetIndex,
            splitTarget: splitTarget,
            focus: focus,
            focusWindow: focusWindow
        )
#if DEBUG
        dlog(
            "surface.moveBonsplit.end tab=\(tabId.uuidString.prefix(5)) panel=\(located.panelId.uuidString.prefix(5)) " +
            "moved=\(moved ? 1 : 0) elapsedMs=\(elapsedMs(since: moveStart))"
        )
#endif
        return moved
    }

    func tabManagerFor(windowId: UUID) -> TabManager? {
        mainWindowContexts.values.first(where: { $0.windowId == windowId })?.tabManager
    }

    func windowId(for tabManager: TabManager) -> UUID? {
        mainWindowContexts.values.first(where: { $0.tabManager === tabManager })?.windowId
    }

    func mainWindow(for windowId: UUID) -> NSWindow? {
        windowForMainWindowId(windowId)
    }

    func mainWindowContainingWorkspace(_ workspaceId: UUID) -> NSWindow? {
        for context in mainWindowContexts.values where context.tabManager.tabs.contains(where: { $0.id == workspaceId }) {
            if let window = context.window ?? windowForMainWindowId(context.windowId) {
                return window
            }
        }
        return nil
    }

    func scriptableMainWindows() -> [ScriptableMainWindowState] {
        var results: [ScriptableMainWindowState] = []
        var seen: Set<UUID> = []

        for window in NSApp.orderedWindows {
            guard let context = contextForMainTerminalWindow(window, reindex: false) else { continue }
            guard seen.insert(context.windowId).inserted else { continue }
            results.append(
                ScriptableMainWindowState(
                    windowId: context.windowId,
                    tabManager: context.tabManager,
                    window: context.window ?? windowForMainWindowId(context.windowId)
                )
            )
        }

        let remaining = mainWindowContexts.values
            .sorted { $0.windowId.uuidString < $1.windowId.uuidString }
            .filter { seen.insert($0.windowId).inserted }

        for context in remaining {
            results.append(
                ScriptableMainWindowState(
                    windowId: context.windowId,
                    tabManager: context.tabManager,
                    window: context.window ?? windowForMainWindowId(context.windowId)
                )
            )
        }

        return results
    }

    func scriptableMainWindow(windowId: UUID) -> ScriptableMainWindowState? {
        guard let context = mainWindowContexts.values.first(where: { $0.windowId == windowId }) else {
            return nil
        }
        return ScriptableMainWindowState(
            windowId: context.windowId,
            tabManager: context.tabManager,
            window: context.window ?? windowForMainWindowId(context.windowId)
        )
    }

    func scriptableMainWindowForTab(_ tabId: UUID) -> ScriptableMainWindowState? {
        guard let context = contextContainingTabId(tabId) else { return nil }
        return ScriptableMainWindowState(
            windowId: context.windowId,
            tabManager: context.tabManager,
            window: context.window ?? windowForMainWindowId(context.windowId)
        )
    }

    @discardableResult
    func focusScriptableMainWindow(windowId: UUID, bringToFront shouldBringToFront: Bool) -> Bool {
        guard let state = scriptableMainWindow(windowId: windowId),
              let window = state.window else {
            return false
        }
        setActiveMainWindow(window)
        if shouldBringToFront {
            bringToFront(window)
        }
        return true
    }

    @discardableResult
    func addWorkspace(windowId: UUID, workingDirectory: String? = nil, bringToFront shouldBringToFront: Bool = false) -> UUID? {
        guard let state = scriptableMainWindow(windowId: windowId) else { return nil }
        if shouldBringToFront, let window = state.window {
            setActiveMainWindow(window)
            bringToFront(window)
        }
        let workspace = state.tabManager.addWorkspace(
            workingDirectory: workingDirectory,
            select: shouldBringToFront
        )
        return workspace.id
    }

    private func markCommandPaletteOpenRequested(for window: NSWindow?) {
        guard let window,
              let windowId = mainWindowId(for: window) else { return }
        commandPalettePendingOpenByWindowId[windowId] = true
        commandPaletteRecentRequestAtByWindowId[windowId] = ProcessInfo.processInfo.systemUptime
    }

    private func postCommandPaletteRequest(
        name: Notification.Name,
        preferredWindow: NSWindow?,
        source: String,
        markPending: Bool
    ) {
        let targetWindow = preferredWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        if markPending {
            markCommandPaletteOpenRequested(for: targetWindow)
        }
        NotificationCenter.default.post(name: name, object: targetWindow)
#if DEBUG
        dlog(
            "shortcut.palette.request source=\(source) " +
            "target={\(debugWindowToken(targetWindow))} " +
            "pendingMarked=\(markPending ? 1 : 0)"
        )
#endif
    }

    func requestCommandPaletteCommands(preferredWindow: NSWindow? = nil, source: String = "api.commandPalette") {
        postCommandPaletteRequest(
            name: .commandPaletteRequested,
            preferredWindow: preferredWindow,
            source: source,
            markPending: true
        )
    }

    func requestCommandPaletteSwitcher(preferredWindow: NSWindow? = nil, source: String = "api.commandPaletteSwitcher") {
        postCommandPaletteRequest(
            name: .commandPaletteSwitcherRequested,
            preferredWindow: preferredWindow,
            source: source,
            markPending: true
        )
    }

    func requestCommandPaletteRenameTab(preferredWindow: NSWindow? = nil, source: String = "api.commandPaletteRenameTab") {
        postCommandPaletteRequest(
            name: .commandPaletteRenameTabRequested,
            preferredWindow: preferredWindow,
            source: source,
            markPending: true
        )
    }

    func requestCommandPaletteRenameWorkspace(
        preferredWindow: NSWindow? = nil,
        source: String = "api.commandPaletteRenameWorkspace"
    ) {
        postCommandPaletteRequest(
            name: .commandPaletteRenameWorkspaceRequested,
            preferredWindow: preferredWindow,
            source: source,
            markPending: true
        )
    }

    func requestCommandPaletteEditWorkspaceDescription(
        preferredWindow: NSWindow? = nil,
        source: String = "api.commandPaletteEditWorkspaceDescription"
    ) {
        postCommandPaletteRequest(
            name: .commandPaletteEditWorkspaceDescriptionRequested,
            preferredWindow: preferredWindow,
            source: source,
            markPending: true
        )
    }

    private func clearCommandPalettePendingOpen(for window: NSWindow?) {
        guard let window,
              let windowId = mainWindowId(for: window) else { return }
        commandPalettePendingOpenByWindowId.removeValue(forKey: windowId)
        commandPaletteRecentRequestAtByWindowId.removeValue(forKey: windowId)
    }

    private func pruneExpiredCommandPalettePendingOpenStates(
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        for windowId in Array(commandPalettePendingOpenByWindowId.keys) {
            guard commandPalettePendingOpenByWindowId[windowId] == true else { continue }
            guard let requestedAt = commandPaletteRecentRequestAtByWindowId[windowId] else {
                commandPalettePendingOpenByWindowId.removeValue(forKey: windowId)
#if DEBUG
                dlog("shortcut.palette.pendingPrune windowId=\(windowId.uuidString.prefix(8)) reason=missingTimestamp")
#endif
                continue
            }
            let age = now - requestedAt
            guard age > Self.commandPalettePendingOpenMaxAge else { continue }
            commandPalettePendingOpenByWindowId.removeValue(forKey: windowId)
            commandPaletteRecentRequestAtByWindowId.removeValue(forKey: windowId)
#if DEBUG
            dlog(
                "shortcut.palette.pendingPrune windowId=\(windowId.uuidString.prefix(8)) " +
                "reason=stale ageMs=\(Int(age * 1000))"
            )
#endif
        }
    }

    private func isCommandPalettePendingOpen(for window: NSWindow) -> Bool {
        guard let windowId = mainWindowId(for: window) else { return false }
        pruneExpiredCommandPalettePendingOpenStates()
        return commandPalettePendingOpenByWindowId[windowId] == true
    }

    private func beginCommandPaletteEscapeSuppression(for window: NSWindow?) {
        guard let window,
              let windowId = mainWindowId(for: window) else { return }
        commandPaletteEscapeSuppressionByWindowId.insert(windowId)
        commandPaletteEscapeSuppressionStartedAtByWindowId[windowId] = ProcessInfo.processInfo.systemUptime
    }

    private func endCommandPaletteEscapeSuppression(for window: NSWindow?) {
        guard let window,
              let windowId = mainWindowId(for: window) else { return }
        commandPaletteEscapeSuppressionByWindowId.remove(windowId)
        commandPaletteEscapeSuppressionStartedAtByWindowId.removeValue(forKey: windowId)
    }

    private func shouldConsumeSuppressedEscape(event: NSEvent, window: NSWindow?) -> Bool {
        guard let window,
              let windowId = mainWindowId(for: window),
              commandPaletteEscapeSuppressionByWindowId.contains(windowId) else {
            return false
        }
        let startedAt = commandPaletteEscapeSuppressionStartedAtByWindowId[windowId] ?? 0
        if ProcessInfo.processInfo.systemUptime - startedAt <= 0.35 {
            return true
        }
        // Fallback cleanup when keyUp is lost for any reason.
        endCommandPaletteEscapeSuppression(for: window)
        return false
    }

    private func recentCommandPaletteRequestAge(for window: NSWindow?) -> TimeInterval? {
        guard let window,
              let windowId = mainWindowId(for: window) else {
            return nil
        }
        let now = ProcessInfo.processInfo.systemUptime
        pruneExpiredCommandPalettePendingOpenStates(now: now)
        guard commandPalettePendingOpenByWindowId[windowId] == true else {
            commandPaletteRecentRequestAtByWindowId.removeValue(forKey: windowId)
            return nil
        }
        guard let startedAt = commandPaletteRecentRequestAtByWindowId[windowId] else {
            commandPalettePendingOpenByWindowId.removeValue(forKey: windowId)
            return nil
        }
        let age = now - startedAt
        if age <= Self.commandPaletteRequestGraceInterval {
            return age
        }
        return nil
    }

    private func escapeSuppressionWindow(for event: NSEvent) -> NSWindow? {
        commandPaletteWindowForShortcutEvent(event) ?? event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
    }

    @discardableResult
    private func clearEscapeSuppressionForKeyUp(event: NSEvent, consumeIfSuppressed: Bool = false) -> Bool {
        guard event.type == .keyUp, event.keyCode == 53 else { return false }
        let suppressionWindow = escapeSuppressionWindow(for: event)
        let didConsume = consumeIfSuppressed && shouldConsumeSuppressedEscape(event: event, window: suppressionWindow)
        if let window = suppressionWindow {
            endCommandPaletteEscapeSuppression(for: window)
#if DEBUG
            dlog(
                "shortcut.escape suppressionClear target={\(debugWindowToken(window))} " +
                "keyUpConsumed=\(didConsume ? 1 : 0)"
            )
#endif
            return didConsume
        }
        commandPaletteEscapeSuppressionByWindowId.removeAll()
        commandPaletteEscapeSuppressionStartedAtByWindowId.removeAll()
#if DEBUG
        dlog("shortcut.escape suppressionClear target={nil} clearedAll=1 keyUpConsumed=\(didConsume ? 1 : 0)")
#endif
        return didConsume
    }

    func setCommandPaletteVisible(_ visible: Bool, for window: NSWindow) {
        guard let windowId = mainWindowId(for: window) else { return }
        let wasVisible = commandPaletteVisibilityByWindowId[windowId] ?? false
        commandPaletteVisibilityByWindowId[windowId] = visible
        // Opening (false -> true) always resolves pending-open.
        // Closing (true -> false) also clears stale pending state.
        // Ignore repeated false updates so a stale sync cannot erase an in-flight open request.
        if visible || wasVisible {
            commandPalettePendingOpenByWindowId.removeValue(forKey: windowId)
            commandPaletteRecentRequestAtByWindowId.removeValue(forKey: windowId)
        }
#if DEBUG
        if !visible,
           !wasVisible,
           commandPalettePendingOpenByWindowId[windowId] == true {
            dlog(
                "palette.visibility.retainPending " +
                "window={\(debugWindowToken(window))} visible=0 wasVisible=0 pending=1"
            )
        }
#endif
    }

    func isCommandPaletteVisible(windowId: UUID) -> Bool {
        commandPaletteVisibilityByWindowId[windowId] ?? false
    }

    func setCommandPaletteSelectionIndex(_ index: Int, for window: NSWindow) {
        guard let windowId = mainWindowId(for: window) else { return }
        commandPaletteSelectionByWindowId[windowId] = max(0, index)
    }

    func commandPaletteSelectionIndex(windowId: UUID) -> Int {
        commandPaletteSelectionByWindowId[windowId] ?? 0
    }

    func setCommandPaletteSnapshot(_ snapshot: CommandPaletteDebugSnapshot, for window: NSWindow) {
        guard let windowId = mainWindowId(for: window) else { return }
        commandPaletteSnapshotByWindowId[windowId] = snapshot
    }

    func commandPaletteSnapshot(windowId: UUID) -> CommandPaletteDebugSnapshot {
        commandPaletteSnapshotByWindowId[windowId] ?? .empty
    }

    func isCommandPaletteVisible(for window: NSWindow) -> Bool {
        guard let windowId = mainWindowId(for: window) else { return false }
        return commandPaletteVisibilityByWindowId[windowId] ?? false
    }

    func isCommandPaletteEffectivelyVisible(for window: NSWindow) -> Bool {
        isCommandPaletteEffectivelyVisible(in: window)
    }

    func shouldBlockFirstResponderChangeWhileCommandPaletteVisible(
        window: NSWindow,
        responder: NSResponder?
    ) -> Bool {
        guard isCommandPaletteVisible(for: window) else { return false }
        guard let responder else { return false }
        guard !isCommandPaletteResponder(responder) else { return false }
        return isFocusStealingResponderWhileCommandPaletteVisible(responder)
    }

    private func isCommandPaletteResponder(_ responder: NSResponder) -> Bool {
        if let textView = responder as? NSTextView, textView.isFieldEditor {
            if let delegateView = textView.delegate as? NSView {
                return isInsideCommandPaletteOverlay(delegateView)
            }
            // SwiftUI can attach a non-view delegate to TextField editors.
            // When command palette is visible, its search/rename editor is the
            // only expected field editor inside the main window.
            return true
        }
        if let view = responder as? NSView {
            return isInsideCommandPaletteOverlay(view)
        }
        return false
    }

    private func isFocusStealingResponderWhileCommandPaletteVisible(_ responder: NSResponder) -> Bool {
        isCommandPaletteFocusStealingTerminalOrBrowserResponder(responder)
    }

    private func isInsideCommandPaletteOverlay(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let candidate = current {
            if candidate.identifier == commandPaletteOverlayContainerIdentifier {
                return true
            }
            current = candidate.superview
        }
        return false
    }

    private func keyRoutingOwnerView(for responder: NSResponder?) -> NSView? {
        guard let responder else { return nil }
        if let editor = responder as? NSTextView,
           editor.isFieldEditor {
            return cmuxFieldEditorOwnerView(editor) ?? editor
        }
        return responder as? NSView
    }

    private func responderHasViableKeyRoutingOwner(
        _ responder: NSResponder,
        in window: NSWindow
    ) -> Bool {
        if let ghosttyView = cmuxOwningGhosttyView(for: responder) {
            if ghosttyView.window !== window {
                return false
            }
            if ghosttyView.isHiddenOrHasHiddenAncestor {
                return false
            }
            return ghosttyView === window.contentView || ghosttyView.superview != nil
        }

        guard let ownerView = keyRoutingOwnerView(for: responder) else {
            return false
        }

        if ownerView.window !== window {
            return false
        }

        if ownerView.isHiddenOrHasHiddenAncestor {
            return false
        }

        if ownerView !== window.contentView, ownerView.superview == nil {
            return false
        }

        return true
    }

    private func responderNeedsFocusedTerminalKeyRepair(
        _ responder: NSResponder?,
        in window: NSWindow,
        hostedView: GhosttySurfaceScrollView
    ) -> Bool {
        guard let responder else { return true }
        if responder is NSWindow { return true }
        guard responderHasViableKeyRoutingOwner(responder, in: window) else {
            return true
        }
        if hostedView.responderMatchesPreferredKeyboardFocus(responder) {
            return false
        }
        return true
    }

    func repairFocusedTerminalKeyboardRoutingIfNeeded(
        window: NSWindow,
        event: NSEvent
    ) {
        guard event.type == .keyDown else { return }
        let normalizedFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !normalizedFlags.contains(.command) else { return }
        guard isMainTerminalWindow(window) else { return }
        guard window.attachedSheet == nil else { return }
        guard !isCommandPaletteEffectivelyVisible(in: window) else { return }
        guard let context = contextForMainWindow(window) ?? contextForMainTerminalWindow(window),
              let workspace = context.tabManager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            return
        }
        guard responderNeedsFocusedTerminalKeyRepair(
            window.firstResponder,
            in: window,
            hostedView: terminalPanel.hostedView
        ) else { return }

#if DEBUG
        let before = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let target = terminalPanel.hostedView.preferredPanelFocusIntentForActivation()
        dlog(
            "focus.keyRepair attempt window=\(ObjectIdentifier(window)) " +
            "workspace=\(String(workspace.id.uuidString.prefix(5))) " +
            "panel=\(String(panelId.uuidString.prefix(5))) " +
            "target=\(target == .findField ? "searchField" : "surface") " +
            "fr=\(before) keyCode=\(event.keyCode) mods=\(event.modifierFlags.rawValue)"
        )
#endif

        terminalPanel.hostedView.ensureFocus(for: workspace.id, surfaceId: panelId)

#if DEBUG
        let after = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        dlog(
            "focus.keyRepair result window=\(ObjectIdentifier(window)) " +
            "panel=\(String(panelId.uuidString.prefix(5))) " +
            "isSurfaceResponder=\(terminalPanel.hostedView.isSurfaceViewFirstResponder() ? 1 : 0) " +
            "fr=\(after)"
        )
#endif
    }

    func locateSurface(surfaceId: UUID) -> (windowId: UUID, workspaceId: UUID, tabManager: TabManager)? {
        for ctx in mainWindowContexts.values {
            for ws in ctx.tabManager.tabs {
                if ws.panels[surfaceId] != nil {
                    return (ctx.windowId, ws.id, ctx.tabManager)
                }
            }
        }
        return nil
    }

    /// Resolve the workspace that currently owns a panel/surface ID.
    /// Prefer the provided workspace when available, then fall back to global lookup.
    func workspaceContainingPanel(
        panelId: UUID,
        preferredWorkspaceId: UUID? = nil
    ) -> (workspace: Workspace, tabManager: TabManager)? {
        if let preferredWorkspaceId,
           let manager = tabManagerFor(tabId: preferredWorkspaceId),
           let workspace = manager.tabs.first(where: { $0.id == preferredWorkspaceId }),
           workspace.panels[panelId] != nil {
            return (workspace, manager)
        }

        if let located = locateSurface(surfaceId: panelId),
           let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
           workspace.panels[panelId] != nil {
            return (workspace, located.tabManager)
        }

        if let preferredWorkspaceId,
           let manager = tabManagerFor(tabId: preferredWorkspaceId) ?? tabManager,
           let workspace = manager.tabs.first(where: { $0.id == preferredWorkspaceId }),
           workspace.panels[panelId] != nil {
            return (workspace, manager)
        }

        if let manager = tabManager,
           let workspace = manager.tabs.first(where: { $0.panels[panelId] != nil }) {
            return (workspace, manager)
        }

        return nil
    }

    func locateGhosttySurface(_ surface: ghostty_surface_t?) -> (windowId: UUID, workspaceId: UUID, panelId: UUID, tabManager: TabManager)? {
        guard let surface else { return nil }
        for ctx in mainWindowContexts.values {
            for ws in ctx.tabManager.tabs {
                for (panelId, panel) in ws.panels {
                    guard let terminal = panel as? TerminalPanel else { continue }
                    if terminal.surface.surface == surface {
                        return (ctx.windowId, ws.id, panelId, ctx.tabManager)
                    }
                }
            }
        }
        return nil
    }

    func refreshTerminalSurfacesAfterGhosttyConfigReload(source: String) {
        var refreshedCount = 0
        forEachTerminalPanel { terminalPanel in
            terminalPanel.hostedView.refreshHostBackgroundAfterGhosttyConfigReload()
            terminalPanel.hostedView.reconcileGeometryNow()
            terminalPanel.surface.forceRefresh(reason: "appDelegate.refreshAfterGhosttyConfigReload")
            refreshedCount += 1
        }
#if DEBUG
        dlog("reload.config.surfaceRefresh source=\(source) count=\(refreshedCount)")
#endif
    }

    private func forEachTerminalPanel(_ body: (TerminalPanel) -> Void) {
        var seenManagers: Set<ObjectIdentifier> = []

        func visitManager(_ manager: TabManager?) {
            guard let manager else { return }
            let managerId = ObjectIdentifier(manager)
            guard seenManagers.insert(managerId).inserted else { return }
            for workspace in manager.tabs {
                for panel in workspace.panels.values {
                    guard let terminalPanel = panel as? TerminalPanel else { continue }
                    body(terminalPanel)
                }
            }
        }

        visitManager(tabManager)
        for context in mainWindowContexts.values {
            visitManager(context.tabManager)
        }
    }

    func focusMainWindow(windowId: UUID) -> Bool {
        guard let window = windowForMainWindowId(windowId) else { return false }
        if TerminalController.shouldSuppressSocketCommandActivation(),
           !TerminalController.socketCommandAllowsInAppFocusMutations() {
            setActiveMainWindow(window)
            return true
        }
        bringToFront(window)
        return true
    }

    func closeMainWindow(windowId: UUID) -> Bool {
        guard let window = windowForMainWindowId(windowId) else { return false }
        window.performClose(nil)
        return true
    }

    private func confirmCloseMainWindow(_ window: NSWindow) -> Bool {
#if DEBUG
        if let debugCloseMainWindowConfirmationHandler {
            return debugCloseMainWindowConfirmationHandler(window)
        }
#endif

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "dialog.closeWindow.title", defaultValue: "Close window?")
        alert.informativeText = String(
            localized: "dialog.closeWindow.message",
            defaultValue: "This will close the current window and all of its workspaces."
        )
        alert.addButton(withTitle: String(localized: "common.close", defaultValue: "Close"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))

        let alertWindow = alert.window
        if let closeButton = alert.buttons.first {
            alertWindow.defaultButtonCell = closeButton.cell as? NSButtonCell
            alertWindow.initialFirstResponder = closeButton
            DispatchQueue.main.async {
                _ = alertWindow.makeFirstResponder(closeButton)
            }
        }

        return alert.runModal() == .alertFirstButtonReturn
    }

    @discardableResult
    func closeWindowWithConfirmation(_ window: NSWindow) -> Bool {
        guard isMainTerminalWindow(window) else {
            window.performClose(nil)
            return true
        }
        guard confirmCloseMainWindow(window) else { return true }
        window.performClose(nil)
        return true
    }

    private func orderedMainWindowSummaries(referenceWindowId: UUID?) -> [MainWindowSummary] {
        let summaries = listMainWindowSummaries()
        return summaries.sorted { lhs, rhs in
            let lhsIsReference = lhs.windowId == referenceWindowId
            let rhsIsReference = rhs.windowId == referenceWindowId
            if lhsIsReference != rhsIsReference { return lhsIsReference }
            if lhs.isKeyWindow != rhs.isKeyWindow { return lhs.isKeyWindow }
            if lhs.isVisible != rhs.isVisible { return lhs.isVisible }
            return lhs.windowId.uuidString < rhs.windowId.uuidString
        }
    }

    private func windowLabelsById(orderedSummaries: [MainWindowSummary], referenceWindowId: UUID?) -> [UUID: String] {
        var labels: [UUID: String] = [:]
        for (index, summary) in orderedSummaries.enumerated() {
            if summary.windowId == referenceWindowId {
                labels[summary.windowId] = String(localized: "menu.currentWindow", defaultValue: "Current Window")
            } else {
                let number = index + 1
                labels[summary.windowId] = String(localized: "menu.windowNumber", defaultValue: "Window \(number)")
            }
        }
        return labels
    }

    private func workspaceDisplayName(_ workspace: Workspace) -> String {
        let trimmed = workspace.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "workspace.displayName.fallback", defaultValue: "Workspace") : trimmed
    }

    private func rollbackDetachedSurface(
        _ detached: Workspace.DetachedSurfaceTransfer,
        to workspace: Workspace,
        sourcePane: PaneID?,
        sourceIndex: Int?,
        focus: Bool
    ) {
        let rollbackPane = sourcePane.flatMap { pane in
            workspace.bonsplitController.allPaneIds.first(where: { $0 == pane })
        } ?? workspace.bonsplitController.focusedPaneId
            ?? workspace.bonsplitController.allPaneIds.first
        guard let rollbackPane else { return }
        _ = workspace.attachDetachedSurface(
            detached,
            inPane: rollbackPane,
            atIndex: sourceIndex,
            focus: focus
        )
    }

    private func cleanupEmptySourceWorkspaceAfterSurfaceMove(
        sourceWorkspace: Workspace,
        sourceManager: TabManager,
        sourceWindowId: UUID
    ) {
        guard sourceWorkspace.panels.isEmpty else { return }
        guard sourceManager.tabs.contains(where: { $0.id == sourceWorkspace.id }) else { return }

        if sourceManager.tabs.count > 1 {
            sourceManager.closeWorkspace(sourceWorkspace)
        } else {
            _ = closeMainWindow(windowId: sourceWindowId)
        }
    }

    private func reassertCrossWindowSurfaceMoveFocusIfNeeded(
        destinationWindowId: UUID,
        sourceWindowId: UUID,
        destinationWorkspaceId: UUID,
        destinationPanelId: UUID,
        destinationManager: TabManager
    ) {
        let reassert: () -> Void = { [weak self, weak destinationManager] in
            guard let self, let destinationManager else { return }
            guard let workspace = destinationManager.tabs.first(where: { $0.id == destinationWorkspaceId }),
                  workspace.panels[destinationPanelId] != nil else {
                return
            }
            guard let destinationWindow = self.mainWindow(for: destinationWindowId) else { return }
            guard let keyWindow = NSApp.keyWindow,
                  let keyWindowId = self.mainWindowId(for: keyWindow),
                  keyWindowId == sourceWindowId,
                  keyWindow !== destinationWindow else {
                return
            }

            self.bringToFront(destinationWindow)
            destinationManager.focusTab(
                destinationWorkspaceId,
                surfaceId: destinationPanelId,
                suppressFlash: true
            )
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: reassert)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: reassert)
    }

    private func windowForMainWindowId(_ windowId: UUID) -> NSWindow? {
        if let ctx = mainWindowContexts.values.first(where: { $0.windowId == windowId }),
           let window = ctx.window {
            return window
        }
        let expectedIdentifier = "cmux.main.\(windowId.uuidString)"
        return NSApp.windows.first(where: { $0.identifier?.rawValue == expectedIdentifier })
    }

    private func resolvedWindow(for context: MainWindowContext) -> NSWindow? {
        if let window = context.window {
            return window
        }
        guard let window = windowForMainWindowId(context.windowId) else {
            return nil
        }
        reindexMainWindowContextIfNeeded(context, for: window)
        return window
    }

    private func mainWindowId(from window: NSWindow) -> UUID? {
        guard let raw = window.identifier?.rawValue else { return nil }
        let prefix = "cmux.main."
        guard raw.hasPrefix(prefix) else { return nil }
        let suffix = String(raw.dropFirst(prefix.count))
        return UUID(uuidString: suffix)
    }

    private func reindexMainWindowContextIfNeeded(_ context: MainWindowContext, for window: NSWindow) {
        let desiredKey = ObjectIdentifier(window)
        if mainWindowContexts[desiredKey] === context {
            context.window = window
            return
        }

        let contextKeys = mainWindowContexts.compactMap { key, value in
            value === context ? key : nil
        }
        for key in contextKeys {
            mainWindowContexts.removeValue(forKey: key)
        }

        if let conflicting = mainWindowContexts[desiredKey], conflicting !== context {
            context.window = window
            return
        }

        mainWindowContexts[desiredKey] = context
        context.window = window
        notifyMainWindowContextsDidChange()
    }

    private func contextForMainTerminalWindow(_ window: NSWindow, reindex: Bool = true) -> MainWindowContext? {
        guard isMainTerminalWindow(window) else { return nil }

        if let context = mainWindowContexts[ObjectIdentifier(window)] {
            context.window = window
            return context
        }

        if let windowId = mainWindowId(from: window),
           let context = mainWindowContexts.values.first(where: { $0.windowId == windowId }) {
            if reindex {
                reindexMainWindowContextIfNeeded(context, for: window)
            } else {
                context.window = window
            }
            return context
        }

        let windowNumber = window.windowNumber
        if windowNumber >= 0,
           let context = mainWindowContexts.values.first(where: { candidate in
               let candidateWindow = candidate.window ?? windowForMainWindowId(candidate.windowId)
               return candidateWindow?.windowNumber == windowNumber
           }) {
            if reindex {
                reindexMainWindowContextIfNeeded(context, for: window)
            } else {
                context.window = window
            }
            return context
        }

        return nil
    }

    private func unregisterMainWindowContext(for window: NSWindow) -> MainWindowContext? {
        guard let removed = contextForMainTerminalWindow(window, reindex: false) else { return nil }
        let removedKeys = mainWindowContexts.compactMap { key, value in
            value === removed ? key : nil
        }
        for key in removedKeys {
            mainWindowContexts.removeValue(forKey: key)
        }
        notifyMainWindowContextsDidChange()
        return removed
    }

    private func discardOrphanedMainWindowContext(_ context: MainWindowContext) {
        let contextKeys = mainWindowContexts.compactMap { key, value in
            value === context ? key : nil
        }
        for key in contextKeys {
            mainWindowContexts.removeValue(forKey: key)
        }
        notifyMainWindowContextsDidChange()

        commandPaletteVisibilityByWindowId.removeValue(forKey: context.windowId)
        commandPalettePendingOpenByWindowId.removeValue(forKey: context.windowId)
        commandPaletteRecentRequestAtByWindowId.removeValue(forKey: context.windowId)
        commandPaletteEscapeSuppressionByWindowId.remove(context.windowId)
        commandPaletteEscapeSuppressionStartedAtByWindowId.removeValue(forKey: context.windowId)
        commandPaletteSelectionByWindowId.removeValue(forKey: context.windowId)
        commandPaletteSnapshotByWindowId.removeValue(forKey: context.windowId)

        if tabManager === context.tabManager {
            if let nextContext = mainWindowContexts.values.first(where: { resolvedWindow(for: $0) != nil }) {
                tabManager = nextContext.tabManager
                sidebarState = nextContext.sidebarState
                sidebarSelectionState = nextContext.sidebarSelectionState
                TerminalController.shared.setActiveTabManager(nextContext.tabManager)
            } else {
                tabManager = nil
                sidebarState = nil
                sidebarSelectionState = nil
                TerminalController.shared.setActiveTabManager(nil)
            }
        }

        if let store = notificationStore {
            for tab in context.tabManager.tabs {
                store.clearNotifications(forTabId: tab.id)
            }
        }
    }

    private func mainWindowId(for window: NSWindow) -> UUID? {
        if let context = mainWindowContexts[ObjectIdentifier(window)] {
            return context.windowId
        }
        guard let rawIdentifier = window.identifier?.rawValue,
              rawIdentifier.hasPrefix("cmux.main.") else { return nil }
        let idPart = String(rawIdentifier.dropFirst("cmux.main.".count))
        return UUID(uuidString: idPart)
    }

    private func commandPaletteOverlayContainer(in window: NSWindow) -> NSView? {
        guard let searchRoot = window.contentView?.superview ?? window.contentView else { return nil }
        var stack: [NSView] = [searchRoot]
        while let candidate = stack.popLast() {
            if candidate.identifier == commandPaletteOverlayContainerIdentifier {
                return candidate
            }
            stack.append(contentsOf: candidate.subviews)
        }
        return nil
    }

    private func isCommandPaletteOverlayPresented(in window: NSWindow) -> Bool {
        guard let container = commandPaletteOverlayContainer(in: window) else { return false }
        return !container.isHidden && container.alphaValue > 0.001
    }

    private func isCommandPaletteResponderActive(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder else { return false }
        if let textView = responder as? NSTextView,
           textView.isFieldEditor,
           !(textView.delegate is NSView) {
            // Field-editor delegates can be non-view responders. Confirm the overlay is
            // mounted and visible to avoid treating unrelated editors as palette input.
            return isCommandPaletteOverlayPresented(in: window)
        }
        return isCommandPaletteResponder(responder)
    }

    private func isCommandPaletteMultilineTextResponderActive(in window: NSWindow) -> Bool {
        guard let textView = window.firstResponder as? NSTextView,
              !textView.isFieldEditor else {
            return false
        }
        return isCommandPaletteResponder(textView)
    }

    private func commandPaletteMarkedTextInput(in window: NSWindow) -> NSTextView? {
        if let textView = window.firstResponder as? NSTextView,
           isCommandPaletteResponder(textView),
           textView.hasMarkedText() {
            return textView
        }

        if let textField = window.firstResponder as? NSTextField,
           let editor = textField.currentEditor() as? NSTextView,
           isCommandPaletteResponder(editor),
           editor.hasMarkedText() {
            return editor
        }

        return nil
    }

    private func isCommandPaletteEffectivelyVisible(in window: NSWindow) -> Bool {
        isCommandPaletteVisible(for: window)
            || isCommandPalettePendingOpen(for: window)
            || isCommandPaletteOverlayPresented(in: window)
            || isCommandPaletteResponderActive(in: window)
    }

    private func activeCommandPaletteWindow() -> NSWindow? {
        pruneExpiredCommandPalettePendingOpenStates()
        if let keyWindow = NSApp.keyWindow,
           isMainTerminalWindow(keyWindow),
           isCommandPaletteEffectivelyVisible(in: keyWindow) {
            return keyWindow
        }
        if let mainWindow = NSApp.mainWindow,
           isMainTerminalWindow(mainWindow),
           isCommandPaletteEffectivelyVisible(in: mainWindow) {
            return mainWindow
        }
        if let orderedWindow = NSApp.orderedWindows.first(where: { window in
            isMainTerminalWindow(window) && isCommandPaletteEffectivelyVisible(in: window)
        }) {
            return orderedWindow
        }
        if let visibleWindowId = commandPaletteVisibilityByWindowId.first(where: { $0.value })?.key {
            return windowForMainWindowId(visibleWindowId)
        }
        if let pendingWindowId = commandPalettePendingOpenByWindowId.first(where: { $0.value })?.key {
            return windowForMainWindowId(pendingWindowId)
        }
        return nil
    }

    private func commandPaletteWindowForShortcutEvent(_ event: NSEvent) -> NSWindow? {
        if let scopedWindow = mainWindowForShortcutEvent(event) {
            return scopedWindow
        }
        return activeCommandPaletteWindow()
    }

    private func contextForMainWindow(_ window: NSWindow?) -> MainWindowContext? {
        guard let window, isMainTerminalWindow(window) else { return nil }
        return mainWindowContexts[ObjectIdentifier(window)]
    }

#if DEBUG
    private func debugManagerToken(_ manager: TabManager?) -> String {
        guard let manager else { return "nil" }
        return String(describing: Unmanaged.passUnretained(manager).toOpaque())
    }

    private func debugWindowToken(_ window: NSWindow?) -> String {
        guard let window else { return "nil" }
        let id = mainWindowId(for: window).map { String($0.uuidString.prefix(8)) } ?? "none"
        let ident = window.identifier?.rawValue ?? "nil"
        let shortIdent: String
        if ident.count > 120 {
            shortIdent = String(ident.prefix(120)) + "..."
        } else {
            shortIdent = ident
        }
        return "num=\(window.windowNumber) id=\(id) ident=\(shortIdent) key=\(window.isKeyWindow ? 1 : 0) main=\(window.isMainWindow ? 1 : 0)"
    }

    private func debugContextToken(_ context: MainWindowContext?) -> String {
        guard let context else { return "nil" }
        let selected = context.tabManager.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        let hasWindow = (context.window != nil || windowForMainWindowId(context.windowId) != nil) ? 1 : 0
        return "id=\(String(context.windowId.uuidString.prefix(8))) mgr=\(debugManagerToken(context.tabManager)) tabs=\(context.tabManager.tabs.count) selected=\(selected) hasWindow=\(hasWindow)"
    }

    private func debugShortcutRouteSnapshot(event: NSEvent? = nil) -> String {
        let activeManager = tabManager
        let activeWindowId = activeManager.flatMap { windowId(for: $0) }.map { String($0.uuidString.prefix(8)) } ?? "nil"
        let selectedWorkspace = activeManager?.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"

        let contexts = mainWindowContexts.values
            .map { context in
                let marker = (activeManager != nil && context.tabManager === activeManager) ? "*" : "-"
                let window = context.window ?? windowForMainWindowId(context.windowId)
                let selected = context.tabManager.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
                return "\(marker)\(String(context.windowId.uuidString.prefix(8))){mgr=\(debugManagerToken(context.tabManager)),win=\(window?.windowNumber ?? -1),key=\((window?.isKeyWindow ?? false) ? 1 : 0),main=\((window?.isMainWindow ?? false) ? 1 : 0),tabs=\(context.tabManager.tabs.count),selected=\(selected)}"
            }
            .sorted()
            .joined(separator: ",")

        let eventWindowNumber = event.map { String($0.windowNumber) } ?? "nil"
        let eventWindow = event?.window
        return "eventWinNum=\(eventWindowNumber) eventWin={\(debugWindowToken(eventWindow))} keyWin={\(debugWindowToken(NSApp.keyWindow))} mainWin={\(debugWindowToken(NSApp.mainWindow))} activeMgr=\(debugManagerToken(activeManager)) activeWinId=\(activeWindowId) activeSelected=\(selectedWorkspace) contexts=[\(contexts)]"
    }
#endif

    private func mainWindowForShortcutEvent(_ event: NSEvent) -> NSWindow? {
        if let window = resolvedShortcutEventWindow(event),
           isMainTerminalWindow(window) {
            return window
        }
        if let keyWindow = NSApp.keyWindow, isMainTerminalWindow(keyWindow) {
            return keyWindow
        }
        if let mainWindow = NSApp.mainWindow, isMainTerminalWindow(mainWindow) {
            return mainWindow
        }
        return nil
    }

    private func resolvedShortcutEventWindow(_ event: NSEvent) -> NSWindow? {
        if let window = event.window {
            return window
        }
        let eventWindowNumber = event.windowNumber
        guard eventWindowNumber > 0 else { return nil }
        return NSApp.window(withWindowNumber: eventWindowNumber)
    }

    /// Re-sync app-level active window pointers from the currently focused main terminal window.
    /// This keeps menu/shortcut actions window-scoped even if the cached `tabManager` drifts.
    @discardableResult
    func synchronizeActiveMainWindowContext(preferredWindow: NSWindow? = nil) -> TabManager? {
        let (context, source): (MainWindowContext?, String) = {
            if let preferredWindow,
               let context = contextForMainWindow(preferredWindow) {
                return (context, "preferredWindow")
            }
            if let context = contextForMainWindow(NSApp.keyWindow) {
                return (context, "keyWindow")
            }
            if let context = contextForMainWindow(NSApp.mainWindow) {
                return (context, "mainWindow")
            }
            if let activeManager = tabManager,
               let activeContext = mainWindowContexts.values.first(where: { $0.tabManager === activeManager }) {
                return (activeContext, "activeManager")
            }
            return (mainWindowContexts.values.first, "firstContextFallback")
        }()

#if DEBUG
        let beforeManagerToken = debugManagerToken(tabManager)
        dlog(
            "shortcut.sync.pre source=\(source) preferred={\(debugWindowToken(preferredWindow))} chosen={\(debugContextToken(context))} \(debugShortcutRouteSnapshot())"
        )
#endif
        guard let context else { return tabManager }
        let alreadyActive =
            tabManager === context.tabManager
            && sidebarState === context.sidebarState
            && sidebarSelectionState === context.sidebarSelectionState
        if alreadyActive {
#if DEBUG
            dlog(
                "shortcut.sync.post source=\(source) beforeMgr=\(beforeManagerToken) afterMgr=\(debugManagerToken(tabManager)) chosen={\(debugContextToken(context))} nochange=1 \(debugShortcutRouteSnapshot())"
            )
#endif
            return context.tabManager
        }
        if let window = context.window ?? windowForMainWindowId(context.windowId) {
            setActiveMainWindow(window)
        } else {
            tabManager = context.tabManager
            sidebarState = context.sidebarState
            sidebarSelectionState = context.sidebarSelectionState
            TerminalController.shared.setActiveTabManager(context.tabManager)
        }
#if DEBUG
        dlog(
            "shortcut.sync.post source=\(source) beforeMgr=\(beforeManagerToken) afterMgr=\(debugManagerToken(tabManager)) chosen={\(debugContextToken(context))} \(debugShortcutRouteSnapshot())"
        )
#endif
        return context.tabManager
    }

    private struct FocusedTerminalShortcutContext {
        let tabManager: TabManager
        let workspaceId: UUID
        let panelId: UUID
    }

    private func resolveShortcutTabManager(for tabId: UUID, preferredWindow: NSWindow? = nil) -> TabManager? {
        if let manager = tabManagerFor(tabId: tabId) {
            return manager
        }
        if let preferredWindow,
           let context = contextForMainWindow(preferredWindow),
           context.tabManager.tabs.contains(where: { $0.id == tabId }) {
            return context.tabManager
        }
        if let activeManager = tabManager,
           activeManager.tabs.contains(where: { $0.id == tabId }) {
            return activeManager
        }
        return nil
    }

    private func focusedTerminalShortcutContext(preferredWindow: NSWindow? = nil) -> FocusedTerminalShortcutContext? {
        let targetWindow = preferredWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        let responder = targetWindow?.firstResponder
            ?? NSApp.keyWindow?.firstResponder
            ?? NSApp.mainWindow?.firstResponder
        guard let ghosttyView = cmuxOwningGhosttyView(for: responder),
              let workspaceId = ghosttyView.tabId,
              let panelId = ghosttyView.terminalSurface?.id,
              let manager = resolveShortcutTabManager(for: workspaceId, preferredWindow: targetWindow) else {
            return nil
        }
        return FocusedTerminalShortcutContext(
            tabManager: manager,
            workspaceId: workspaceId,
            panelId: panelId
        )
    }

    private func preferredMainWindowContextForShortcuts(event: NSEvent) -> MainWindowContext? {
        if let context = contextForMainWindow(event.window) {
            return context
        }
        if let context = contextForMainWindow(NSApp.keyWindow) {
            return context
        }
        if let context = contextForMainWindow(NSApp.mainWindow) {
            return context
        }
        if let activeManager = tabManager,
           let activeContext = mainWindowContexts.values.first(where: { $0.tabManager === activeManager }) {
            return activeContext
        }
        return mainWindowContexts.values.first
    }

    private func activateMainWindowContextForShortcutEvent(_ event: NSEvent) {
        let preferredWindow = mainWindowForShortcutEvent(event)
#if DEBUG
        dlog(
            "shortcut.activate.pre event=\(NSWindow.keyDescription(event)) preferred={\(debugWindowToken(preferredWindow))} \(debugShortcutRouteSnapshot(event: event))"
        )
#endif
        _ = synchronizeActiveMainWindowContext(preferredWindow: preferredWindow)
#if DEBUG
        dlog(
            "shortcut.activate.post event=\(NSWindow.keyDescription(event)) preferred={\(debugWindowToken(preferredWindow))} \(debugShortcutRouteSnapshot(event: event))"
        )
#endif
    }

    @discardableResult
    func toggleSidebarInActiveMainWindow() -> Bool {
        if let activeManager = tabManager,
           let activeContext = mainWindowContexts.values.first(where: { $0.tabManager === activeManager }) {
            if let window = activeContext.window ?? windowForMainWindowId(activeContext.windowId) {
                setActiveMainWindow(window)
            }
            activeContext.sidebarState.toggle()
            return true
        }
        if let keyContext = contextForMainWindow(NSApp.keyWindow) {
            if let window = keyContext.window ?? windowForMainWindowId(keyContext.windowId) {
                setActiveMainWindow(window)
            }
            keyContext.sidebarState.toggle()
            return true
        }
        if let mainContext = contextForMainWindow(NSApp.mainWindow) {
            if let window = mainContext.window ?? windowForMainWindowId(mainContext.windowId) {
                setActiveMainWindow(window)
            }
            mainContext.sidebarState.toggle()
            return true
        }
        if let fallbackContext = mainWindowContexts.values.first {
            if let window = fallbackContext.window ?? windowForMainWindowId(fallbackContext.windowId) {
                setActiveMainWindow(window)
            }
            fallbackContext.sidebarState.toggle()
            return true
        }
        if let sidebarState {
            sidebarState.toggle()
            return true
        }
        return false
    }

    func sidebarVisibility(windowId: UUID) -> Bool? {
        mainWindowContexts.values.first(where: { $0.windowId == windowId })?.sidebarState.isVisible
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu(title: "")
        let newWindowItem = NSMenuItem(
            title: String(localized: "menu.file.newWindow", defaultValue: "New Window"),
            action: #selector(openNewMainWindow(_:)),
            keyEquivalent: ""
        )
        newWindowItem.target = self
        menu.addItem(newWindowItem)
        return menu
    }

    @objc func openNewMainWindow(_ sender: Any?) {
        _ = createMainWindow()
    }

    /// Shows the "Open Folder" panel and creates a workspace for the selected directory.
    /// Called from both the SwiftUI menu and `handleCustomShortcut`.
    func showOpenFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = String(localized: "menu.file.openFolder.panelTitle", defaultValue: "Open Folder")
        panel.prompt = String(localized: "menu.file.openFolder.panelPrompt", defaultValue: "Open")
        // Seed the panel with the active workspace's directory. Use the shared
        // main-window resolver so this works even when an auxiliary window is key.
        if let context = preferredMainWindowContextForWorkspaceCreation(debugSource: "openFolderPanel.seed"),
           let cwd = context.tabManager.selectedWorkspace?.currentDirectory,
           !cwd.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: cwd)
        }
        if panel.runModal() == .OK, let url = panel.url {
            openWorkspaceForExternalDirectory(
                workingDirectory: url.path,
                debugSource: "shortcut.openFolder"
            )
        }
    }

    @discardableResult
    func openDirectoryInInlineVSCode(
        _ directoryURL: URL,
        tabManager preferredTabManager: TabManager? = nil
    ) -> Bool {
        guard let vscodeApplicationURL = TerminalDirectoryOpenTarget.vscodeInline.applicationURL() else {
            return false
        }

        let targetTabManager = preferredTabManager
            ?? preferredMainWindowContextForWorkspaceCreation(debugSource: "inlineVSCode.open.target")?.tabManager
        guard let targetTabManager else {
            return false
        }

        let targetWorkspaceId = targetTabManager.selectedWorkspace?.id
            ?? targetTabManager.tabs.first?.id
            ?? targetTabManager.addWorkspace(select: true).id
        let normalizedDirectoryURL = directoryURL.standardizedFileURL

        VSCodeServeWebController.shared.ensureServeWebURL(vscodeApplicationURL: vscodeApplicationURL) { serveWebURL in
            guard let serveWebURL,
                  let openFolderURL = VSCodeServeWebURLBuilder.openFolderURL(
                      baseWebUIURL: serveWebURL,
                      directoryPath: normalizedDirectoryURL.path
                  ) else {
                NSSound.beep()
                return
            }

            guard targetTabManager.openBrowser(
                inWorkspace: targetWorkspaceId,
                url: openFolderURL,
                preferSplitRight: true
            ) != nil else {
                NSSound.beep()
                return
            }
        }

        return true
    }

    func showOpenFolderInInlineVSCodePanel(tabManager preferredTabManager: TabManager? = nil) {
        guard TerminalDirectoryOpenTarget.vscodeInline.isAvailable() else {
            NSSound.beep()
            return
        }

        let targetTabManager = preferredTabManager
            ?? preferredMainWindowContextForWorkspaceCreation(debugSource: "inlineVSCode.panel.target")?.tabManager
        guard let targetTabManager else {
            NSSound.beep()
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = String(
            localized: "menu.file.openFolderInVSCodeInline.panelTitle",
            defaultValue: "Open Folder in VS Code (Inline)"
        )
        panel.prompt = String(
            localized: "menu.file.openFolderInVSCodeInline.panelPrompt",
            defaultValue: "Open in VS Code"
        )
        if let cwd = targetTabManager.selectedWorkspace?.currentDirectory,
           !cwd.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: cwd)
        }

        if panel.runModal() == .OK,
           let url = panel.url,
           !openDirectoryInInlineVSCode(url, tabManager: targetTabManager) {
            NSSound.beep()
        }
    }

    @objc func openWindow(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        openFromServicePasteboard(pasteboard, target: .window, error: error)
    }

    @objc func openTab(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        openFromServicePasteboard(pasteboard, target: .workspace, error: error)
    }

    private enum ServiceOpenTarget {
        case window
        case workspace
    }

    private func openFromServicePasteboard(
        _ pasteboard: NSPasteboard,
        target: ServiceOpenTarget,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        let pathURLs = servicePathURLs(from: pasteboard)
        guard !pathURLs.isEmpty else {
            error.pointee = Self.serviceErrorNoPath
            return
        }

        let directories = externalOpenDirectories(from: pathURLs)
        guard !directories.isEmpty else {
            error.pointee = Self.serviceErrorNoPath
            return
        }

        prepareForExplicitOpenIntentAtStartup()
        for directory in directories {
            switch target {
            case .window:
                _ = createMainWindow(initialWorkingDirectory: directory)
            case .workspace:
                openWorkspaceFromService(workingDirectory: directory)
            }
        }
    }

    private func servicePathURLs(from pasteboard: NSPasteboard) -> [URL] {
        if let pathURLs = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !pathURLs.isEmpty {
            return pathURLs
        }

        let filenamesType = NSPasteboard.PasteboardType(rawValue: "NSFilenamesPboardType")
        if let paths = pasteboard.propertyList(forType: filenamesType) as? [String] {
            let urls = paths.map { URL(fileURLWithPath: $0) }
            if !urls.isEmpty {
                return urls
            }
        }

        if let raw = pasteboard.string(forType: .string), !raw.isEmpty {
            return raw
                .split(whereSeparator: \.isNewline)
                .map { line in
                    let text = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let fileURL = URL(string: text), fileURL.isFileURL {
                        return fileURL
                    }
                    return URL(fileURLWithPath: text)
                }
        }

        return []
    }

    private func openWorkspaceFromService(workingDirectory: String) {
        openWorkspaceForExternalDirectory(
            workingDirectory: workingDirectory,
            debugSource: "service.openTab"
        )
    }

    private func prepareForExplicitOpenIntentAtStartup() {
        didHandleExplicitOpenIntentAtStartup = true
        if !didAttemptStartupSessionRestore {
            startupSessionSnapshot = nil
            didAttemptStartupSessionRestore = true
        }
    }

    private func externalOpenDirectories(from urls: [URL]) -> [String] {
        // LaunchServices can surface the running app bundle on relaunch; ignore self paths so
        // they do not get treated as explicit folder opens and suppress session restore.
        FinderServicePathResolver.orderedUniqueDirectories(
            from: urls.filter { $0.isFileURL },
            excludingDescendantsOf: [Bundle.main.bundleURL]
        )
    }

    private func openWorkspaceForExternalDirectory(
        workingDirectory: String,
        debugSource: String
    ) {
        if addWorkspaceInPreferredMainWindow(
            workingDirectory: workingDirectory,
            shouldBringToFront: true,
            debugSource: debugSource
        ) != nil {
            return
        }
        _ = createMainWindow(initialWorkingDirectory: workingDirectory)
    }

    @discardableResult
    func addWorkspaceInPreferredMainWindow(
        workingDirectory: String? = nil,
        shouldBringToFront: Bool = false,
        event: NSEvent? = nil,
        debugSource: String = "unspecified"
    ) -> UUID? {
        #if DEBUG
        logWorkspaceCreationRouting(
            phase: "request",
            source: debugSource,
            reason: "add_workspace",
            event: event,
            chosenContext: nil,
            workingDirectory: workingDirectory
        )
        #endif
        guard let context = preferredMainWindowContextForWorkspaceCreation(event: event, debugSource: debugSource) else {
            #if DEBUG
            logWorkspaceCreationRouting(
                phase: "no_context",
                source: debugSource,
                reason: "context_selection_failed",
                event: event,
                chosenContext: nil,
                workingDirectory: workingDirectory
            )
            #endif
            return nil
        }
        guard let window = resolvedWindow(for: context) else {
            #if DEBUG
            logWorkspaceCreationRouting(
                phase: "no_context",
                source: debugSource,
                reason: "context_window_missing",
                event: event,
                chosenContext: context,
                workingDirectory: workingDirectory
            )
            #endif
            discardOrphanedMainWindowContext(context)
            return nil
        }
        setActiveMainWindow(window)
        if shouldBringToFront {
            bringToFront(window)
        }

        let workspace: Workspace
        if let workingDirectory {
            workspace = context.tabManager.addWorkspace(workingDirectory: workingDirectory, select: true)
        } else {
            workspace = context.tabManager.addTab(select: true)
        }
        #if DEBUG
        logWorkspaceCreationRouting(
            phase: "created",
            source: debugSource,
            reason: "workspace_created",
            event: event,
            chosenContext: context,
            workspaceId: workspace.id,
            workingDirectory: workingDirectory
        )
        #endif
        return workspace.id
    }

    private func preferredMainWindowContextForWorkspaceCreation(
        event: NSEvent? = nil,
        debugSource: String = "unspecified"
    ) -> MainWindowContext? {
        if let context = mainWindowContext(forShortcutEvent: event, debugSource: debugSource) {
            return context
        }

        // If a keyboard event identifies a specific window but that context
        // can't be resolved, do not fall back to another window.
        if shortcutEventHasAddressableWindow(event) {
#if DEBUG
            logWorkspaceCreationRouting(
                phase: "choose",
                source: debugSource,
                reason: "event_context_required_no_fallback",
                event: event,
                chosenContext: nil
            )
#endif
            return nil
        }

        if let keyWindow = NSApp.keyWindow,
           let context = contextForMainTerminalWindow(keyWindow) {
#if DEBUG
            logWorkspaceCreationRouting(
                phase: "choose",
                source: debugSource,
                reason: "key_window",
                event: event,
                chosenContext: context
            )
            #endif
            return context
        }

        if let mainWindow = NSApp.mainWindow,
           let context = contextForMainTerminalWindow(mainWindow) {
            #if DEBUG
            logWorkspaceCreationRouting(
                phase: "choose",
                source: debugSource,
                reason: "main_window",
                event: event,
                chosenContext: context
            )
            #endif
            return context
        }

        for window in NSApp.orderedWindows where isMainTerminalWindow(window) {
            if let context = contextForMainTerminalWindow(window) {
                #if DEBUG
                logWorkspaceCreationRouting(
                    phase: "choose",
                    source: debugSource,
                    reason: "ordered_windows",
                    event: event,
                    chosenContext: context
                )
                #endif
                return context
            }
        }

        let fallback = mainWindowContexts.values.first(where: { resolvedWindow(for: $0) != nil })
        #if DEBUG
        logWorkspaceCreationRouting(
            phase: "choose",
            source: debugSource,
            reason: "fallback_first_context",
            event: event,
            chosenContext: fallback
        )
#endif
        return fallback
    }

    private func shortcutEventHasAddressableWindow(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        // NSEvent.windowNumber can be 0 for responder-chain events that are not
        // actually bound to an NSWindow (notably some WebKit key paths).
        return event.window != nil || event.windowNumber > 0
    }

    private func mainWindowContext(
        forShortcutEvent event: NSEvent?,
        debugSource: String = "unspecified"
    ) -> MainWindowContext? {
        guard let event else { return nil }

        if let eventWindow = event.window,
           let context = contextForMainTerminalWindow(eventWindow) {
            #if DEBUG
            logWorkspaceCreationRouting(
                phase: "choose",
                source: debugSource,
                reason: "event_window",
                event: event,
                chosenContext: context
            )
            #endif
            return context
        }

        if event.windowNumber > 0,
           let numberedWindow = NSApp.window(withWindowNumber: event.windowNumber),
           let context = contextForMainTerminalWindow(numberedWindow) {
            #if DEBUG
            logWorkspaceCreationRouting(
                phase: "choose",
                source: debugSource,
                reason: "event_window_number",
                event: event,
                chosenContext: context
            )
            #endif
            return context
        }

        if event.windowNumber > 0,
           let context = mainWindowContexts.values.first(where: { candidate in
               let window = candidate.window ?? windowForMainWindowId(candidate.windowId)
               return window?.windowNumber == event.windowNumber
           }) {
            #if DEBUG
            logWorkspaceCreationRouting(
                phase: "choose",
                source: debugSource,
                reason: "event_window_number_scan",
                event: event,
                chosenContext: context
            )
            #endif
            return context
        }

        #if DEBUG
        logWorkspaceCreationRouting(
            phase: "choose",
            source: debugSource,
            reason: "event_context_not_found",
            event: event,
            chosenContext: nil
        )
        #endif
        return nil
    }

    private func preferredMainWindowContextForShortcutRouting(event: NSEvent) -> MainWindowContext? {
        if let context = mainWindowContext(forShortcutEvent: event, debugSource: "shortcut.routing") {
            return context
        }

        if shortcutEventHasAddressableWindow(event) {
            if let eventWindow = resolvedShortcutEventWindow(event),
               cmuxWindowShouldOwnCloseShortcut(eventWindow) {
                // Auxiliary cmux windows do not own a terminal tab manager. Let them fall back
                // to the active main terminal window so app shortcuts like Cmd+W still route.
            } else {
#if DEBUG
                logWorkspaceCreationRouting(
                    phase: "choose",
                    source: "shortcut.routing",
                    reason: "event_context_required_no_fallback",
                    event: event,
                    chosenContext: nil
                )
#endif
                return nil
            }
        }

        if let keyWindow = NSApp.keyWindow,
           let context = contextForMainTerminalWindow(keyWindow) {
            return context
        }

        if let mainWindow = NSApp.mainWindow,
           let context = contextForMainTerminalWindow(mainWindow) {
            return context
        }

        if let activeManager = tabManager,
           let context = mainWindowContexts.values.first(where: { $0.tabManager === activeManager }) {
            return context
        }

        return mainWindowContexts.values.first
    }

    @discardableResult
    private func synchronizeShortcutRoutingContext(event: NSEvent) -> Bool {
        guard let context = preferredMainWindowContextForShortcutRouting(event: event) else {
#if DEBUG
            FocusLogStore.shared.append(
                "shortcut.route reason=no_context_no_fallback eventWin=\(event.windowNumber) keyCode=\(event.keyCode)"
            )
#endif
            return false
        }

        let alreadyActive =
            tabManager === context.tabManager
            && sidebarState === context.sidebarState
            && sidebarSelectionState === context.sidebarSelectionState
        if alreadyActive { return true }

        if let window = context.window ?? windowForMainWindowId(context.windowId) {
            setActiveMainWindow(window)
        } else {
            tabManager = context.tabManager
            sidebarState = context.sidebarState
            sidebarSelectionState = context.sidebarSelectionState
            TerminalController.shared.setActiveTabManager(context.tabManager)
        }

#if DEBUG
        FocusLogStore.shared.append(
            "shortcut.route reason=sync activeTM=\(pointerString(tabManager)) chosen={\(summarizeContextForWorkspaceRouting(context))}"
        )
#endif
        return true
    }

    @discardableResult
    func createMainWindow(
        initialWorkingDirectory: String? = nil,
        sessionWindowSnapshot: SessionWindowSnapshot? = nil
    ) -> UUID {
        let windowId = UUID()
        let tabManager = TabManager(initialWorkingDirectory: initialWorkingDirectory)
        if let tabManagerSnapshot = sessionWindowSnapshot?.tabManager {
            tabManager.restoreSessionSnapshot(tabManagerSnapshot)
        }

        let sidebarWidth = sessionWindowSnapshot?.sidebar.width
            .map(SessionPersistencePolicy.sanitizedSidebarWidth)
            ?? SessionPersistencePolicy.defaultSidebarWidth
        let sidebarState = SidebarState(
            isVisible: sessionWindowSnapshot?.sidebar.isVisible ?? true,
            persistedWidth: CGFloat(sidebarWidth)
        )
        let sidebarSelectionState = SidebarSelectionState(
            selection: sessionWindowSnapshot?.sidebar.selection.sidebarSelection ?? .tabs
        )
        let notificationStore = TerminalNotificationStore.shared

        let cmuxConfigStore = CmuxConfigStore()
        cmuxConfigStore.wireDirectoryTracking(tabManager: tabManager)
        cmuxConfigStore.loadAll()

        let root = ContentView(updateViewModel: updateViewModel, windowId: windowId)
            .environmentObject(tabManager)
            .environmentObject(notificationStore)
            .environmentObject(sidebarState)
            .environmentObject(sidebarSelectionState)
            .environmentObject(cmuxConfigStore)

        // Use the current key window's size for new windows so Cmd+Shift+N
        // creates a window matching the previous one's dimensions.
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        let sourceContext = preferredMainWindowContextForWorkspaceCreation(
            debugSource: "createMainWindow.initialGeometry"
        )
        let sourceWindow = sourceContext.flatMap { resolvedWindow(for: $0) }
        let existingFrame = sourceWindow?.frame
        let sourceWindowIsNativeFullScreen: Bool = {
#if DEBUG
            if let debugCreateMainWindowSourceIsNativeFullScreenOverride {
                return debugCreateMainWindowSourceIsNativeFullScreenOverride
            }
#endif
            return sourceWindow?.styleMask.contains(.fullScreen) == true
        }()
        let shouldTemporarilyDisallowFullScreenTiling =
            sessionWindowSnapshot == nil && sourceWindowIsNativeFullScreen
        let initialRect: NSRect
        if sessionWindowSnapshot == nil, let existingFrame {
            // Convert frame rect to content rect so the new window matches the
            // source window's actual size (frame includes titlebar insets).
            initialRect = NSWindow.contentRect(forFrameRect: existingFrame, styleMask: styleMask)
        } else {
            initialRect = NSRect(x: 0, y: 0, width: 460, height: 360)
        }

        let window = NSWindow(
            contentRect: initialRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        // When creating a new window from an existing native fullscreen window,
        // temporarily opt out of fullscreen tiling so AppKit doesn't place the
        // new window into the active fullscreen Space.
        if shouldTemporarilyDisallowFullScreenTiling {
            window.collectionBehavior.insert(.fullScreenDisallowsTiling)
        }
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.isMovable = false
        let restoredFrame = resolvedWindowFrame(from: sessionWindowSnapshot)
        if let restoredFrame {
            window.setFrame(restoredFrame, display: false)
        } else {
            window.center()
            // Cascade using the same algorithm as upstream Ghostty: seed from
            // the window's own top-left on the first call, then advance the
            // cascade point for each subsequent window.
            if mainWindowContexts.count >= 1 {
                lastCascadePoint = window.cascadeTopLeft(from: lastCascadePoint)
            } else {
                lastCascadePoint = window.cascadeTopLeft(from: NSPoint(x: window.frame.minX, y: window.frame.maxY))
            }
        }
        window.contentView = MainWindowHostingView(rootView: root)

        // Apply shared window styling.
        attachUpdateAccessory(to: window)
        applyWindowDecorations(to: window)

        // Keep a strong reference so the window isn't deallocated.
        let controller = MainWindowController(window: window)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.mainWindowControllers.removeAll(where: { $0 === controller })
        }
        window.delegate = controller
        mainWindowControllers.append(controller)

        registerMainWindow(
            window,
            windowId: windowId,
            tabManager: tabManager,
            sidebarState: sidebarState,
            sidebarSelectionState: sidebarSelectionState
        )
        installFileDropOverlay(on: window, tabManager: tabManager)
        if TerminalController.shouldSuppressSocketCommandActivation() {
            window.orderFront(nil)
            if TerminalController.socketCommandAllowsInAppFocusMutations() {
                setActiveMainWindow(window)
            }
        } else {
            window.makeKeyAndOrderFront(nil)
            setActiveMainWindow(window)
            NSApp.activate(ignoringOtherApps: true)
        }
        if shouldTemporarilyDisallowFullScreenTiling {
            DispatchQueue.main.async { [weak window] in
                window?.collectionBehavior.remove(.fullScreenDisallowsTiling)
            }
        }
        if let restoredFrame {
            window.setFrame(restoredFrame, display: true)
#if DEBUG
            dlog(
                "session.restore.frameApplied window=\(windowId.uuidString.prefix(8)) " +
                    "applied={\(debugNSRectDescription(window.frame))}"
            )
#endif
        }
        return windowId
    }

    @objc func checkForUpdates(_ sender: Any?) {
        updateViewModel.overrideState = nil
        updateController.checkForUpdates()
    }

    func checkForUpdatesInCustomUI() {
        updateViewModel.overrideState = nil
        updateController.checkForUpdatesInCustomUI()
    }

    func openWelcomeWorkspace() {
        guard let context = preferredMainWindowContextForWorkspaceCreation(event: nil, debugSource: "welcome") else {
            return
        }
        if let window = context.window ?? windowForMainWindowId(context.windowId) {
            setActiveMainWindow(window)
            bringToFront(window)
        }
        let workspace = context.tabManager.addWorkspace(select: true, autoWelcomeIfNeeded: false)
        sendWelcomeCommandWhenReady(to: workspace)
    }

    func sendWelcomeCommandWhenReady(to workspace: Workspace, markShownOnSend: Bool = false) {
        sendTextWhenReady("cmux welcome\n", to: workspace) {
            if markShownOnSend {
                UserDefaults.standard.set(true, forKey: WelcomeSettings.shownKey)
            }
        }
    }

    @objc func applyUpdateIfAvailable(_ sender: Any?) {
        updateViewModel.overrideState = nil
        updateController.installUpdate()
    }

    @objc func attemptUpdate(_ sender: Any?) {
        updateViewModel.overrideState = nil
        updateController.attemptUpdate()
    }

    func isCmuxCLIInstalledInPATH() -> Bool {
        CmuxCLIPathInstaller().isInstalled()
    }

    @objc func installCmuxCLIInPath(_ sender: Any?) {
        let installer = CmuxCLIPathInstaller()
        do {
            let outcome = try installer.install()
            var informativeText = String(localized: "cli.install.symlinkCreated", defaultValue: "Created symlink:\n\n\(outcome.destinationURL.path) -> \(outcome.sourceURL.path)")
            if outcome.usedAdministratorPrivileges {
                informativeText += "\n\n" + String(localized: "cli.install.adminRequired", defaultValue: "Administrator privileges were required to write to /usr/local/bin.")
            }
            presentCLIPathAlert(
                title: String(localized: "cli.installed", defaultValue: "cmux CLI Installed"),
                informativeText: informativeText,
                style: .informational
            )
        } catch {
            presentCLIPathAlert(
                title: String(localized: "cli.installFailed", defaultValue: "Couldn't Install cmux CLI"),
                informativeText: error.localizedDescription,
                style: .warning
            )
        }
    }

    @objc func uninstallCmuxCLIInPath(_ sender: Any?) {
        let installer = CmuxCLIPathInstaller()
        do {
            let outcome = try installer.uninstall()
            let prefix = outcome.removedExistingEntry
                ? String(localized: "cli.uninstall.removed", defaultValue: "Removed \(outcome.destinationURL.path).")
                : String(localized: "cli.uninstall.notFound", defaultValue: "No cmux CLI symlink was found at \(outcome.destinationURL.path).")
            var informativeText = prefix
            if outcome.usedAdministratorPrivileges {
                informativeText += "\n\n" + String(localized: "cli.uninstall.adminRequired", defaultValue: "Administrator privileges were required to modify /usr/local/bin.")
            }
            presentCLIPathAlert(
                title: String(localized: "cli.uninstalled", defaultValue: "cmux CLI Uninstalled"),
                informativeText: informativeText,
                style: .informational
            )
        } catch {
            presentCLIPathAlert(
                title: String(localized: "cli.uninstallFailed", defaultValue: "Couldn't Uninstall cmux CLI"),
                informativeText: error.localizedDescription,
                style: .warning
            )
        }
    }

    private func presentCLIPathAlert(
        title: String,
        informativeText: String,
        style: NSAlert.Style
    ) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = informativeText
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            _ = alert.runModal()
        }
    }

    @objc func restartSocketListener(_ sender: Any?) {
        guard tabManager != nil else {
            NSSound.beep()
            return
        }

        guard socketListenerConfigurationIfEnabled() != nil else {
            TerminalController.shared.stop()
            NSSound.beep()
            return
        }
        restartSocketListenerIfEnabled(source: "menu.command")
    }

    private func setupMenuBarExtra() {
        guard menuBarExtraController == nil else { return }
        let store = TerminalNotificationStore.shared
        menuBarExtraController = MenuBarExtraController(
            notificationStore: store,
            onShowNotifications: { [weak self] in
                self?.showNotificationsPopoverFromMenuBar()
            },
            onOpenNotification: { [weak self] notification in
                _ = self?.openNotification(
                    tabId: notification.tabId,
                    surfaceId: notification.surfaceId,
                    notificationId: notification.id
                )
            },
            onJumpToLatestUnread: { [weak self] in
                self?.jumpToLatestUnread()
            },
            onCheckForUpdates: { [weak self] in
                self?.checkForUpdates(nil)
            },
            onOpenPreferences: { [weak self] in
                self?.openPreferencesWindow(debugSource: "menuBarExtra")
            },
            onQuitApp: {
                NSApp.terminate(nil)
            }
        )
    }

    private func installMenuBarVisibilityObserver() {
        guard menuBarVisibilityObserver == nil else { return }
        menuBarVisibilityObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncMenuBarExtraVisibility()
            }
        }
    }

    private func syncMenuBarExtraVisibility(defaults: UserDefaults = .standard) {
        if MenuBarExtraSettings.showsMenuBarExtra(defaults: defaults) {
            setupMenuBarExtra()
            return
        }

        menuBarExtraController?.removeFromMenuBar()
        menuBarExtraController = nil
    }

    @MainActor
    static func presentPreferencesWindow(
        navigationTarget: SettingsNavigationTarget? = nil,
        showFallbackSettingsWindow: @MainActor (SettingsNavigationTarget?) -> Void = { target in
            SettingsWindowController.shared.show(navigationTarget: target)
        },
        activateApplication: @MainActor () -> Void = {
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
    ) {
#if DEBUG
        dlog("settings.open.present path=customWindowDirect")
#endif
        showFallbackSettingsWindow(navigationTarget)
        activateApplication()
        if let window = SettingsWindowController.shared.window {
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async {
                window.orderFrontRegardless()
                window.makeKeyAndOrderFront(nil)
            }
        }
#if DEBUG
        dlog("settings.open.present activate=1")
#endif
    }

    @MainActor
    func openPreferencesWindow(debugSource: String, navigationTarget: SettingsNavigationTarget? = nil) {
#if DEBUG
        dlog("settings.open.request source=\(debugSource)")
#endif
        Self.presentPreferencesWindow(navigationTarget: navigationTarget)
    }

    @objc func openPreferencesWindow() {
        openPreferencesWindow(debugSource: "appDelegate")
    }

    func refreshMenuBarExtraForDebug() {
        menuBarExtraController?.refreshForDebugControls()
    }

    func showNotificationsPopoverFromMenuBar() {
        let context: MainWindowContext? = {
            if let keyWindow = NSApp.keyWindow,
               let keyContext = contextForMainTerminalWindow(keyWindow) {
                return keyContext
            }
            if let first = mainWindowContexts.values.first {
                return first
            }
            let windowId = createMainWindow()
            return mainWindowContexts.values.first(where: { $0.windowId == windowId })
        }()

        if let context,
           let window = context.window ?? windowForMainWindowId(context.windowId) {
            setActiveMainWindow(window)
            bringToFront(window)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.titlebarAccessoryController.showNotificationsPopover(animated: false)
        }
    }

    #if DEBUG
    @objc func showUpdatePill(_ sender: Any?) {
        updateViewModel.debugOverrideText = nil
        updateViewModel.overrideState = .installing(.init(isAutoUpdate: true, retryTerminatingApplication: {}, dismiss: {}))
    }

    @objc func showUpdatePillLongNightly(_ sender: Any?) {
        updateViewModel.debugOverrideText = "Update Available: 0.32.0-nightly+20260216.abc1234"
        updateViewModel.overrideState = .notFound(.init(acknowledgement: {}))
    }

    @objc func showUpdatePillLoading(_ sender: Any?) {
        updateViewModel.debugOverrideText = nil
        updateViewModel.overrideState = .checking(.init(cancel: {}))
    }

    @objc func hideUpdatePill(_ sender: Any?) {
        updateViewModel.debugOverrideText = nil
        updateViewModel.overrideState = .idle
    }

    @objc func clearUpdatePillOverride(_ sender: Any?) {
        updateViewModel.debugOverrideText = nil
        updateViewModel.overrideState = nil
    }
#endif

    @objc func copyUpdateLogs(_ sender: Any?) {
        let logText = UpdateLogStore.shared.snapshot()
        let payload: String
        if logText.isEmpty {
            payload = "No update logs captured.\nLog file: \(UpdateLogStore.shared.logPath())"
        } else {
            payload = logText + "\nLog file: \(UpdateLogStore.shared.logPath())"
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
    }
    @objc func copyFocusLogs(_ sender: Any?) {
        let logText = FocusLogStore.shared.snapshot()
        let payload: String
        if logText.isEmpty {
            payload = "No focus logs captured.\nLog file: \(FocusLogStore.shared.logPath())"
        } else {
            payload = logText + "\nLog file: \(FocusLogStore.shared.logPath())"
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
    }

    @objc private func handleReactGrabDidCopySelection(_ notification: Notification) {
        let browserPanelId = notification.userInfo?[ReactGrabPastebackNotificationKey.browserPanelId] as? UUID
        guard let workspaceId = notification.userInfo?[ReactGrabPastebackNotificationKey.workspaceId] as? UUID,
              let returnPanelId = notification.userInfo?[ReactGrabPastebackNotificationKey.returnPanelId] as? UUID,
              let content = notification.userInfo?[ReactGrabPastebackNotificationKey.content] as? String else {
#if DEBUG
            dlog(
                "reactGrab.pasteback h3.didCopy.drop " +
                "reason=missingNotificationFields " +
                "workspace=\(Self.debugShortId(notification.userInfo?[ReactGrabPastebackNotificationKey.workspaceId] as? UUID)) " +
                "browser=\(Self.debugShortId(browserPanelId)) " +
                "return=\(Self.debugShortId(notification.userInfo?[ReactGrabPastebackNotificationKey.returnPanelId] as? UUID)) " +
                "hasContent=\((notification.userInfo?[ReactGrabPastebackNotificationKey.content] as? String) != nil ? 1 : 0)"
            )
#endif
            return
        }

        guard let manager = tabManagerFor(tabId: workspaceId),
              let workspace = manager.tabs.first(where: { $0.id == workspaceId }) else {
#if DEBUG
            dlog(
                "reactGrab.pasteback h3.didCopy.drop " +
                "reason=missingWorkspace workspace=\(Self.debugShortId(workspaceId)) " +
                "browser=\(Self.debugShortId(browserPanelId)) return=\(Self.debugShortId(returnPanelId))"
            )
#endif
            return
        }

        guard workspace.terminalPanel(for: returnPanelId) != nil else {
#if DEBUG
            dlog(
                "reactGrab.pasteback h3.didCopy.drop " +
                "reason=missingReturnTerminal workspace=\(Self.debugShortId(workspaceId)) " +
                "browser=\(Self.debugShortId(browserPanelId)) return=\(Self.debugShortId(returnPanelId)) " +
                "focused=\(Self.debugShortId(workspace.focusedPanelId))"
            )
#endif
            return
        }

#if DEBUG
        dlog(
            "reactGrab.pasteback h3.didCopy " +
            "workspace=\(Self.debugShortId(workspaceId)) " +
            "browser=\(Self.debugShortId(browserPanelId)) " +
            "return=\(Self.debugShortId(returnPanelId)) " +
            "focusedBefore=\(Self.debugShortId(workspace.focusedPanelId)) len=\(content.count)"
        )
#endif
        manager.focusTab(workspaceId, surfaceId: returnPanelId, suppressFlash: true)
#if DEBUG
        dlog(
            "reactGrab.pasteback h1.focusRequested " +
            "workspace=\(Self.debugShortId(workspaceId)) " +
            "return=\(Self.debugShortId(returnPanelId)) " +
            "focusedAfterRequest=\(Self.debugShortId(workspace.focusedPanelId))"
        )
#endif
        sendTextWhenReady(content, to: workspace, preferredPanelId: returnPanelId)
    }

    nonisolated private static func debugShortId(_ id: UUID?) -> String {
        id.map { String($0.uuidString.prefix(5)) } ?? "nil"
    }

    static func resolveTerminalPanelForTextSend(in tab: Tab, preferredPanelId: UUID? = nil) -> TerminalPanel? {
        if let preferredPanelId {
            return tab.terminalPanel(for: preferredPanelId)
        }
        return tab.focusedTerminalPanel
    }

    private func sendTextWhenReady(
        _ text: String,
        to tab: Tab,
        preferredPanelId: UUID? = nil,
        beforeSend: (() -> Void)? = nil
    ) {
        let isReactGrabPasteback = preferredPanelId != nil
#if DEBUG
        let initialTargetPanel = Self.resolveTerminalPanelForTextSend(
            in: tab,
            preferredPanelId: preferredPanelId
        )
        if isReactGrabPasteback {
            dlog(
                "reactGrab.pasteback h2.send.start " +
                "workspace=\(Self.debugShortId(tab.id)) " +
                "preferred=\(Self.debugShortId(preferredPanelId)) " +
                "focused=\(Self.debugShortId(tab.focusedPanelId)) " +
                "focusedTerminal=\(Self.debugShortId(tab.focusedTerminalPanel?.id)) " +
                "resolved=\(Self.debugShortId(initialTargetPanel?.id)) " +
                "surfaceReady=\(initialTargetPanel?.surface.surface != nil ? 1 : 0) len=\(text.count)"
            )
        }
#endif
        if let terminalPanel = Self.resolveTerminalPanelForTextSend(
            in: tab,
            preferredPanelId: preferredPanelId
        ),
           terminalPanel.surface.surface != nil {
#if DEBUG
            if isReactGrabPasteback {
                dlog(
                    "reactGrab.pasteback h2.send.immediate " +
                    "workspace=\(Self.debugShortId(tab.id)) " +
                    "target=\(Self.debugShortId(terminalPanel.id)) len=\(text.count)"
                )
            }
#endif
            beforeSend?()
            terminalPanel.sendText(text)
#if DEBUG
            if isReactGrabPasteback {
                dlog(
                    "reactGrab.pasteback h2.send.sent " +
                    "workspace=\(Self.debugShortId(tab.id)) " +
                    "target=\(Self.debugShortId(terminalPanel.id)) mode=immediate len=\(text.count)"
                )
            }
#endif
            return
        }

        var resolved = false
        var readyObserver: NSObjectProtocol?
        var focusObserver: NSObjectProtocol?
        var firstResponderObserver: NSObjectProtocol?
        var panelsCancellable: AnyCancellable?

        func cleanupObservers() {
            if let readyObserver {
                NotificationCenter.default.removeObserver(readyObserver)
            }
            if let focusObserver {
                NotificationCenter.default.removeObserver(focusObserver)
            }
            if let firstResponderObserver {
                NotificationCenter.default.removeObserver(firstResponderObserver)
            }
            panelsCancellable?.cancel()
        }

        func finishIfReady() {
            let terminalPanel = Self.resolveTerminalPanelForTextSend(
                in: tab,
                preferredPanelId: preferredPanelId
            )
#if DEBUG
            if isReactGrabPasteback {
                dlog(
                    "reactGrab.pasteback h2.finishIfReady " +
                    "workspace=\(Self.debugShortId(tab.id)) " +
                    "preferred=\(Self.debugShortId(preferredPanelId)) " +
                    "focused=\(Self.debugShortId(tab.focusedPanelId)) " +
                    "resolved=\(Self.debugShortId(terminalPanel?.id)) " +
                    "surfaceReady=\(terminalPanel?.surface.surface != nil ? 1 : 0) alreadyResolved=\(resolved ? 1 : 0)"
                )
            }
#endif
            guard !resolved,
                  let terminalPanel,
                  terminalPanel.surface.surface != nil else { return }
            resolved = true
            cleanupObservers()
            beforeSend?()
            terminalPanel.sendText(text)
#if DEBUG
            if isReactGrabPasteback {
                dlog(
                    "reactGrab.pasteback h2.send.sent " +
                    "workspace=\(Self.debugShortId(tab.id)) " +
                    "target=\(Self.debugShortId(terminalPanel.id)) mode=delayed len=\(text.count)"
                )
            }
#endif
        }

        panelsCancellable = tab.$panels
            .map { _ in () }
            .sink { _ in
#if DEBUG
                if isReactGrabPasteback {
                    dlog(
                        "reactGrab.pasteback h2.panelsChanged " +
                        "workspace=\(Self.debugShortId(tab.id)) " +
                        "focused=\(Self.debugShortId(tab.focusedPanelId))"
                    )
                }
#endif
                finishIfReady()
            }
        if isReactGrabPasteback {
            focusObserver = NotificationCenter.default.addObserver(
                forName: .ghosttyDidFocusSurface,
                object: nil,
                queue: .main
            ) { note in
                guard let candidateTabId = note.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                      candidateTabId == tab.id,
                      let candidateSurfaceId = note.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else {
                    return
                }
#if DEBUG
                dlog(
                    "reactGrab.pasteback h1.focusEvent " +
                    "workspace=\(Self.debugShortId(candidateTabId)) " +
                    "surface=\(Self.debugShortId(candidateSurfaceId)) " +
                    "target=\(Self.debugShortId(preferredPanelId)) " +
                    "match=\(candidateSurfaceId == preferredPanelId ? 1 : 0)"
                )
#endif
            }
            firstResponderObserver = NotificationCenter.default.addObserver(
                forName: .ghosttyDidBecomeFirstResponderSurface,
                object: nil,
                queue: .main
            ) { note in
                guard let candidateTabId = note.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                      candidateTabId == tab.id,
                      let candidateSurfaceId = note.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else {
                    return
                }
#if DEBUG
                dlog(
                    "reactGrab.pasteback h1.firstResponderEvent " +
                    "workspace=\(Self.debugShortId(candidateTabId)) " +
                    "surface=\(Self.debugShortId(candidateSurfaceId)) " +
                    "target=\(Self.debugShortId(preferredPanelId)) " +
                    "match=\(candidateSurfaceId == preferredPanelId ? 1 : 0)"
                )
#endif
            }
        }
        readyObserver = NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: nil,
            queue: .main
        ) { note in
            guard let workspaceId = note.userInfo?["workspaceId"] as? UUID,
                  workspaceId == tab.id else { return }
            let surfaceId = note.userInfo?["surfaceId"] as? UUID
#if DEBUG
            if isReactGrabPasteback {
                dlog(
                    "reactGrab.pasteback h2.surfaceReadyEvent " +
                    "workspace=\(Self.debugShortId(workspaceId)) " +
                    "surface=\(Self.debugShortId(surfaceId)) " +
                    "target=\(Self.debugShortId(preferredPanelId)) " +
                    "match=\(surfaceId == preferredPanelId ? 1 : 0)"
                )
            }
#endif
            if let preferredPanelId,
               let surfaceId,
               surfaceId != preferredPanelId {
                return
            }
            finishIfReady()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if !resolved {
#if DEBUG
                if isReactGrabPasteback {
                    dlog(
                        "reactGrab.pasteback h2.send.timeout " +
                        "workspace=\(Self.debugShortId(tab.id)) " +
                        "preferred=\(Self.debugShortId(preferredPanelId)) " +
                        "focused=\(Self.debugShortId(tab.focusedPanelId)) " +
                        "focusedTerminal=\(Self.debugShortId(tab.focusedTerminalPanel?.id))"
                    )
                }
#endif
                cleanupObservers()
                NSLog("Command send: surface not ready after 3.0s")
            }
        }
    }

#if DEBUG
    private let debugColorWorkspaceTitlePrefix = "Debug Color - "
    private let debugPerfWorkspaceTitlePrefix = "Debug Perf - "
    private var debugStressWorkspaceCreationInProgress = false
    private var debugStressLagProbeEnabled = false
    private let debugStressWorkspaceCount = 20
    private let debugStressPaneCount = 4
    private let debugStressTabsPerPane = 4
    private let debugStressYieldInterval = 4
    private let debugStressSurfaceLoadTimeoutSeconds: TimeInterval = 10.0

    @objc func openDebugScrollbackTab(_ sender: Any?) {
        guard let tabManager else { return }
        let tab = tabManager.addTab()
        let config = GhosttyConfig.load()
        let lineCount = min(max(config.scrollbackLimit * 2, 2000), 60000)
        let command = "for i in {1..\(lineCount)}; do printf \"scrollback %06d\\n\" $i; done\n"
        sendTextWhenReady(command, to: tab)
    }

    @objc func openDebugLoremTab(_ sender: Any?) {
        guard let tabManager else { return }
        let tab = tabManager.addTab()
        let lineCount = 2000
        let base = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore."
        var lines: [String] = []
        lines.reserveCapacity(lineCount)
        for index in 1...lineCount {
            lines.append(String(format: "%04d %@", index, base))
        }
        let payload = lines.joined(separator: "\n") + "\n"
        sendTextWhenReady(payload, to: tab)
    }

    @objc func openDebugColorComparisonWorkspaces(_ sender: Any?) {
        guard let tabManager else { return }

        let palette = WorkspaceTabColorSettings.palette()
        guard !palette.isEmpty else { return }

        var existingByTitle: [String: Workspace] = [:]
        for tab in tabManager.tabs {
            guard let title = tab.customTitle,
                  title.hasPrefix(debugColorWorkspaceTitlePrefix) else { continue }
            existingByTitle[title] = tab
        }

        for entry in palette {
            let title = "\(debugColorWorkspaceTitlePrefix)\(entry.name)"
            let targetTab: Workspace
            if let existing = existingByTitle[title] {
                targetTab = existing
            } else {
                targetTab = tabManager.addTab()
            }
            tabManager.setCustomTitle(tabId: targetTab.id, title: title)
            tabManager.setTabColor(tabId: targetTab.id, color: entry.hex)
        }
    }

    @objc func openDebugStressWorkspacesWithLoadedSurfaces(_ sender: Any?) {
        guard !debugStressWorkspaceCreationInProgress else { return }
        guard let tabManager else { return }

        debugStressLagProbeEnabled = true
        debugStressWorkspaceCreationInProgress = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.debugStressWorkspaceCreationInProgress = false }

            let totalStart = ProcessInfo.processInfo.systemUptime
            let originalSelectedWorkspaceId = tabManager.selectedTabId
            var created: [Workspace] = []
            created.reserveCapacity(self.debugStressWorkspaceCount)
            var layoutFailures = 0
            var cumulativeWorkspaceMs: Double = 0
            var slowWorkspaceCount = 0
            var worstWorkspaceMs: Double = 0

            dlog(
                "stress.setup.start workspaces=\(self.debugStressWorkspaceCount) panes=\(self.debugStressPaneCount) " +
                "tabsPerPane=\(self.debugStressTabsPerPane) lagProbe=1"
            )

            for index in 0..<self.debugStressWorkspaceCount {
                let workspaceStart = ProcessInfo.processInfo.systemUptime
                let workspace = tabManager.addWorkspace(select: false, placementOverride: .end)
                created.append(workspace)
                tabManager.setCustomTitle(
                    tabId: workspace.id,
                    title: "\(self.debugPerfWorkspaceTitlePrefix)\(index + 1)"
                )

                if !(await self.configureDebugStressWorkspaceLayout(
                    workspace,
                    paneCount: self.debugStressPaneCount,
                    tabsPerPane: self.debugStressTabsPerPane
                )) {
                    layoutFailures += 1
                }

                let workspaceMs = (ProcessInfo.processInfo.systemUptime - workspaceStart) * 1000.0
                cumulativeWorkspaceMs += workspaceMs
                worstWorkspaceMs = max(worstWorkspaceMs, workspaceMs)
                if workspaceMs >= 35 {
                    slowWorkspaceCount += 1
                }

                if workspaceMs >= 35 || ((index + 1) % 5 == 0) {
                    let pending = self.pendingDebugTerminalSurfaceCount(in: created)
                    dlog(
                        "stress.setup.workspace idx=\(index + 1)/\(self.debugStressWorkspaceCount) " +
                        "ms=\(String(format: "%.2f", workspaceMs)) failures=\(layoutFailures) pending=\(pending)"
                    )
                }

                if ((index + 1) % self.debugStressYieldInterval) == 0 {
                    await Task.yield()
                }
            }

            let creationElapsedMs = (ProcessInfo.processInfo.systemUptime - totalStart) * 1000.0
            let loadStats = await self.loadAllDebugStressWorkspacesForTerminalSurfaceReadiness(
                created,
                tabManager: tabManager
            )
            let totalElapsedMs = (ProcessInfo.processInfo.systemUptime - totalStart) * 1000.0
            let avgWorkspaceMs = created.isEmpty ? 0 : (cumulativeWorkspaceMs / Double(created.count))
            let expectedSurfaceCount = self.debugStressWorkspaceCount
                * self.debugStressPaneCount
                * self.debugStressTabsPerPane
            if let originalSelectedWorkspaceId,
               tabManager.tabs.contains(where: { $0.id == originalSelectedWorkspaceId }) {
                tabManager.selectedTabId = originalSelectedWorkspaceId
            }

            dlog(
                "stress.setup.done createMs=\(String(format: "%.2f", creationElapsedMs)) " +
                "loadMs=\(String(format: "%.2f", loadStats.elapsedMs)) loadedPanels=\(loadStats.loadedPanels) " +
                "loadFailures=\(loadStats.failedPanels) totalMs=\(String(format: "%.2f", totalElapsedMs)) " +
                "workspaceAvgMs=\(String(format: "%.2f", avgWorkspaceMs)) workspaceWorstMs=\(String(format: "%.2f", worstWorkspaceMs)) " +
                "workspaceSlowCount=\(slowWorkspaceCount) waitAttempts=\(loadStats.attempts) " +
                "pendingSurfaces=\(loadStats.pendingSurfaces) expectedSurfaces=\(expectedSurfaceCount)"
            )

            NSLog(
                "Debug stress workspaces: created=%d panesPerWorkspace=%d tabsPerPane=%d expectedSurfaces=%d layoutFailures=%d pendingSurfaces=%d createMs=%.2f loadMs=%.2f loadedPanels=%d failedPanels=%d totalMs=%.2f workspaceAvgMs=%.2f workspaceWorstMs=%.2f waitAttempts=%d",
                self.debugStressWorkspaceCount,
                self.debugStressPaneCount,
                self.debugStressTabsPerPane,
                expectedSurfaceCount,
                layoutFailures,
                loadStats.pendingSurfaces,
                creationElapsedMs,
                loadStats.elapsedMs,
                loadStats.loadedPanels,
                loadStats.failedPanels,
                totalElapsedMs,
                avgWorkspaceMs,
                worstWorkspaceMs,
                loadStats.attempts
            )
        }
    }

    private func configureDebugStressWorkspaceLayout(
        _ workspace: Workspace,
        paneCount: Int,
        tabsPerPane: Int
    ) async -> Bool {
        guard let topLeftPanelId = workspace.focusedTerminalPanel?.id ?? workspace.focusedPanelId else {
            return false
        }
        guard let topRight = workspace.newTerminalSplit(
            from: topLeftPanelId,
            orientation: .horizontal,
            focus: false
        ) else {
            return false
        }
        await Task.yield()
        guard workspace.newTerminalSplit(
            from: topLeftPanelId,
            orientation: .vertical,
            focus: false
        ) != nil else {
            return false
        }
        await Task.yield()
        guard workspace.newTerminalSplit(
            from: topRight.id,
            orientation: .vertical,
            focus: false
        ) != nil else {
            return false
        }
        await Task.yield()

        let paneIds = workspace.bonsplitController.allPaneIds
        guard paneIds.count == paneCount else { return false }

        let additionalTabsPerPane = max(0, tabsPerPane - 1)
        if additionalTabsPerPane > 0 {
            for (paneIndex, paneId) in paneIds.enumerated() {
                for tabOffset in 0..<additionalTabsPerPane {
                    guard workspace.newTerminalSurface(inPane: paneId, focus: false) != nil else {
                        return false
                    }
                    if ((tabOffset + 1) % debugStressYieldInterval) == 0 {
                        await Task.yield()
                    }
                }
                if ((paneIndex + 1) % debugStressYieldInterval) == 0 {
                    await Task.yield()
                }
            }
        }

        return true
    }

    private struct DebugStressSurfaceLoadStats {
        let pendingSurfaces: Int
        let loadedPanels: Int
        let failedPanels: Int
        let attempts: Int
        let elapsedMs: Double
    }

    private struct DebugStressTerminalLoadTarget {
        let workspace: Workspace
        let paneId: PaneID
        let tabId: TabID
        let panelId: UUID
    }

    private func waitForDebugStressCondition(
        timeout: TimeInterval,
        installObservers: (@escaping () -> Void) -> [NSObjectProtocol],
        evaluate: @escaping () -> Bool
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            var observers: [NSObjectProtocol] = []
            var timeoutWorkItem: DispatchWorkItem?
            var finished = false

            func cleanup() {
                observers.forEach { NotificationCenter.default.removeObserver($0) }
                observers.removeAll()
                timeoutWorkItem?.cancel()
                timeoutWorkItem = nil
            }

            func finish(_ result: Bool) {
                guard !finished else { return }
                finished = true
                cleanup()
                continuation.resume(returning: result)
            }

            let trigger = {
                if evaluate() {
                    finish(true)
                }
            }

            observers = installObservers {
                DispatchQueue.main.async {
                    trigger()
                }
            }
            let workItem = DispatchWorkItem {
                finish(evaluate())
            }
            timeoutWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: workItem)
            trigger()
        }
    }

    private func loadAllDebugStressWorkspacesForTerminalSurfaceReadiness(
        _ workspaces: [Workspace],
        tabManager: TabManager
    ) async -> DebugStressSurfaceLoadStats {
        guard !workspaces.isEmpty else {
            return DebugStressSurfaceLoadStats(
                pendingSurfaces: 0,
                loadedPanels: 0,
                failedPanels: 0,
                attempts: 0,
                elapsedMs: 0
            )
        }

        let retainedWorkspaceIds = Set(workspaces.map(\.id))
        let loadStart = ProcessInfo.processInfo.systemUptime
        var attempts = 0
        var queuedTargets: [DebugStressTerminalLoadTarget] = []
        queuedTargets.reserveCapacity(
            workspaces.count * debugStressPaneCount * debugStressTabsPerPane
        )

        tabManager.retainDebugWorkspaceLoads(for: retainedWorkspaceIds)
        defer { tabManager.releaseDebugWorkspaceLoads(for: retainedWorkspaceIds) }

        await Task.yield()
        forceDebugStressVisibleLayout()
        let mountedWorkspaceCount = await waitForDebugStressMountedWorkspaces(workspaces)

        for (workspaceIndex, workspace) in workspaces.enumerated() {
            for paneId in workspace.bonsplitController.allPaneIds {
                for tab in workspace.bonsplitController.tabs(inPane: paneId) {
                    guard let panelId = workspace.panelIdFromSurfaceId(tab.id),
                          workspace.panel(for: tab.id) is TerminalPanel else {
                        continue
                    }
                    if workspace.preloadTerminalPanelForDebugStress(tabId: tab.id, inPane: paneId) != nil {
                        queuedTargets.append(
                            DebugStressTerminalLoadTarget(
                                workspace: workspace,
                                paneId: paneId,
                                tabId: tab.id,
                                panelId: panelId
                            )
                        )
                        attempts += 1
                    }
                }
            }

            dlog(
                "stress.setup.queue workspace=\(workspaceIndex + 1)/\(workspaces.count) " +
                "mounted=\(mountedWorkspaceCount)/\(workspaces.count) queued=\(queuedTargets.count)"
            )
            await Task.yield()
        }

        let waitResult = await waitForDebugStressTerminalPanelSurfaces(queuedTargets)
        attempts += waitResult.attempts
        let failedPanels = waitResult.pendingTargets.count
        let loadedPanels = max(0, queuedTargets.count - failedPanels)
        for target in waitResult.pendingTargets {
            dlog(
                "stress.setup.surfaceTimeout workspace=\(target.workspace.id.uuidString.prefix(5)) " +
                "panel=\(target.panelId.uuidString.prefix(5)) pane=\(target.paneId.id.uuidString.prefix(5))"
            )
        }

        let elapsedMs = (ProcessInfo.processInfo.systemUptime - loadStart) * 1000.0
        return DebugStressSurfaceLoadStats(
            pendingSurfaces: pendingDebugTerminalSurfaceCount(in: workspaces),
            loadedPanels: loadedPanels,
            failedPanels: failedPanels,
            attempts: attempts,
            elapsedMs: elapsedMs
        )
    }

    private func waitForDebugStressMountedWorkspaces(_ workspaces: [Workspace]) async -> Int {
        guard !workspaces.isEmpty else { return 0 }
        var mountedWorkspaceCount = 0
        let selectedWorkspaceId = tabManager?.selectedTabId

        let updateMountedCount = { [self] in
            self.forceDebugStressVisibleLayout()
            mountedWorkspaceCount = 0
            for workspace in workspaces {
                if workspace.id == selectedWorkspaceId {
                    workspace.scheduleDebugStressTerminalGeometryReconcile()
                } else {
                    workspace.requestBackgroundTerminalSurfaceStartIfNeeded()
                }
                if workspace.panels.values.contains(where: { panel in
                    guard let terminalPanel = panel as? TerminalPanel else { return false }
                    return terminalPanel.hostedView.superview != nil || terminalPanel.surface.surface != nil
                }) {
                    mountedWorkspaceCount += 1
                }
            }
        }
        let _ = await waitForDebugStressCondition(
            timeout: 0.25,
            installObservers: { trigger in
                [
                    NotificationCenter.default.addObserver(
                        forName: .terminalSurfaceDidBecomeReady,
                        object: nil,
                        queue: .main
                    ) { _ in
                        trigger()
                    },
                    NotificationCenter.default.addObserver(
                        forName: .terminalSurfaceHostedViewDidMoveToWindow,
                        object: nil,
                        queue: .main
                    ) { _ in
                        trigger()
                    },
                    NotificationCenter.default.addObserver(
                        forName: NSWindow.didUpdateNotification,
                        object: nil,
                        queue: .main
                    ) { _ in
                        trigger()
                    }
                ]
            },
            evaluate: {
                updateMountedCount()
                return mountedWorkspaceCount == workspaces.count
            }
        )

        dlog("stress.setup.mount mounted=\(mountedWorkspaceCount)/\(workspaces.count)")
        return mountedWorkspaceCount
    }

    private func waitForDebugStressTerminalPanelSurfaces(
        _ targets: [DebugStressTerminalLoadTarget]
    ) async -> (pendingTargets: [DebugStressTerminalLoadTarget], attempts: Int) {
        guard !targets.isEmpty else {
            return (pendingTargets: [], attempts: 0)
        }

        let deadline = Date().addingTimeInterval(debugStressSurfaceLoadTimeoutSeconds)
        let selectedWorkspaceId = tabManager?.selectedTabId
        var pendingTargets = targets
        var attempts = 0
        var eventCount = 0

        func refreshPendingTargets() {
            self.forceDebugStressVisibleLayout()
            var nextPending: [DebugStressTerminalLoadTarget] = []
            nextPending.reserveCapacity(pendingTargets.count)
            var startedThisPass = 0

            for target in pendingTargets {
                guard let terminalPanel = target.workspace.panel(for: target.tabId) as? TerminalPanel else {
                    nextPending.append(target)
                    continue
                }
                if terminalPanel.surface.surface != nil {
                    continue
                }

                let hostedView = terminalPanel.hostedView
                let shouldReconcileVisibleSelection =
                    target.workspace.id == selectedWorkspaceId &&
                    hostedView.window != nil &&
                    hostedView.superview != nil

                if shouldReconcileVisibleSelection {
                    target.workspace.scheduleDebugStressTerminalGeometryReconcile()
                    terminalPanel.requestViewReattach()
                }
                terminalPanel.surface.requestBackgroundSurfaceStartIfNeeded()
                startedThisPass += 1
                nextPending.append(target)
            }

            eventCount += 1
            if nextPending.count != pendingTargets.count || startedThisPass > 0 || eventCount == 1 {
                dlog(
                    "stress.setup.await event=\(eventCount) pending=\(nextPending.count) " +
                    "started=\(startedThisPass)"
                )
            }
            attempts += startedThisPass
            pendingTargets = nextPending
        }
        refreshPendingTargets()
        let remaining = deadline.timeIntervalSinceNow
        if remaining > 0, !pendingTargets.isEmpty {
            let _ = await waitForDebugStressCondition(
                timeout: remaining,
                installObservers: { trigger in
                    [
                        NotificationCenter.default.addObserver(
                            forName: .terminalSurfaceDidBecomeReady,
                            object: nil,
                            queue: .main
                        ) { _ in
                            trigger()
                        },
                        NotificationCenter.default.addObserver(
                            forName: .terminalSurfaceHostedViewDidMoveToWindow,
                            object: nil,
                            queue: .main
                        ) { _ in
                            trigger()
                        },
                        NotificationCenter.default.addObserver(
                            forName: NSWindow.didUpdateNotification,
                            object: nil,
                            queue: .main
                        ) { _ in
                            trigger()
                        }
                    ]
                },
                evaluate: {
                    refreshPendingTargets()
                    return pendingTargets.isEmpty
                }
            )
        }

        return (pendingTargets: pendingTargets, attempts: attempts)
    }

    private func forceDebugStressVisibleLayout() {
        if let activeWindow = NSApp.keyWindow ?? NSApp.mainWindow {
            activeWindow.contentView?.layoutSubtreeIfNeeded()
            activeWindow.contentView?.displayIfNeeded()
            return
        }

        for (windowIndex, window) in NSApp.windows.enumerated() {
            window.contentView?.layoutSubtreeIfNeeded()
            if windowIndex == 0 {
                window.contentView?.displayIfNeeded()
            }
        }
    }

    private func pendingDebugTerminalSurfaceCount(in workspaces: [Workspace]) -> Int {
        var pending = 0
        for workspace in workspaces {
            for panel in workspace.panels.values {
                guard let terminalPanel = panel as? TerminalPanel else { continue }
                if terminalPanel.surface.surface == nil {
                    pending += 1
                }
            }
        }
        return pending
    }

    private func debugStressLagSnapshot() -> (
        workspaceCount: Int,
        terminalPanelCount: Int,
        loadedSurfaceCount: Int,
        selectedWorkspace: String
    ) {
        guard let tabManager else {
            return (0, 0, 0, "nil")
        }
        var terminalPanelCount = 0
        var loadedSurfaceCount = 0
        for workspace in tabManager.tabs {
            for panel in workspace.panels.values {
                guard let terminalPanel = panel as? TerminalPanel else { continue }
                terminalPanelCount += 1
                if terminalPanel.surface.surface != nil {
                    loadedSurfaceCount += 1
                }
            }
        }
        let selectedWorkspace = tabManager.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        return (
            tabManager.tabs.count,
            terminalPanelCount,
            loadedSurfaceCount,
            selectedWorkspace
        )
    }

    private func logSlowShortcutMonitorLatencyIfNeeded(
        event: NSEvent,
        handledByShortcut: Bool,
        elapsedMs: Double
    ) {
        guard debugStressLagProbeEnabled else { return }
        guard event.type == .keyDown else { return }

        let normalizedFlags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        let isPlainTyping = normalizedFlags.isDisjoint(with: [.command, .control, .option])
        let thresholdMs: Double = event.isARepeat ? 1.5 : (isPlainTyping ? 2.5 : 6.0)
        guard elapsedMs >= thresholdMs else { return }

        let snapshot = debugStressLagSnapshot()
        dlog(
            "stress.inputLag path=appMonitor ms=\(String(format: "%.2f", elapsedMs)) " +
            "threshold=\(String(format: "%.2f", thresholdMs)) handled=\(handledByShortcut ? 1 : 0) " +
            "plain=\(isPlainTyping ? 1 : 0) repeat=\(event.isARepeat ? 1 : 0) keyCode=\(event.keyCode) " +
            "mods=\(event.modifierFlags.rawValue) workspaces=\(snapshot.workspaceCount) " +
            "terminals=\(snapshot.terminalPanelCount) surfacesReady=\(snapshot.loadedSurfaceCount) " +
            "selected=\(snapshot.selectedWorkspace)"
        )
    }

    @objc func triggerSentryTestCrash(_ sender: Any?) {
        SentrySDK.crash()
    }
#endif

#if DEBUG
    private func setupJumpUnreadUITestIfNeeded() {
        guard !didSetupJumpUnreadUITest else { return }
        didSetupJumpUnreadUITest = true
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" else { return }
        guard let notificationStore else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                // In UI tests, the initial SwiftUI `WindowGroup` window can lag behind launch. Wait for a
                // registered main terminal window context so notifications can be routed back correctly.
                let deadline = Date().addingTimeInterval(8.0)
                @MainActor func waitForContext(_ completion: @escaping (MainWindowContext) -> Void) {
                    if let context = self.mainWindowContexts.values.first,
                       context.window != nil {
                        completion(context)
                        return
                    }
                    guard Date() < deadline else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        Task { @MainActor in
                            waitForContext(completion)
                        }
                    }
                }

                waitForContext { context in
                    let tabManager = context.tabManager
                    let initialIndex = tabManager.tabs.firstIndex(where: { $0.id == tabManager.selectedTabId }) ?? 0
                    let tab = tabManager.addTab()
                    guard let initialPanelId = tab.focusedPanelId else { return }

                    _ = tabManager.newSplit(tabId: tab.id, surfaceId: initialPanelId, direction: .right)
                    guard let targetPanelId = tab.focusedPanelId else { return }
                    // Find another panel that's not the currently focused one
                    let otherPanelId = tab.panels.keys.first(where: { $0 != targetPanelId })
                    if let otherPanelId {
                        tab.focusPanel(otherPanelId)
                    }

                    // Avoid flakiness in the VM where focus can lag selection by a tick, which would
                    // cause notification suppression to incorrectly drop this UI-test notification.
                    let prevOverride = AppFocusState.overrideIsFocused
                    AppFocusState.overrideIsFocused = false
                    notificationStore.addNotification(
                        tabId: tab.id,
                        surfaceId: targetPanelId,
                        title: "JumpToUnread",
                        subtitle: "",
                        body: ""
                    )
                    AppFocusState.overrideIsFocused = prevOverride

                    self.writeJumpUnreadTestData([
                        "expectedTabId": tab.id.uuidString,
                        "expectedSurfaceId": targetPanelId.uuidString
                    ])

                    tabManager.selectTab(at: initialIndex)
                }
            }
        }
    }

    func recordJumpToUnreadFocus(tabId: UUID, surfaceId: UUID) {
        writeJumpUnreadTestData([
            "focusedTabId": tabId.uuidString,
            "focusedSurfaceId": surfaceId.uuidString
        ])
    }

    func armJumpUnreadFocusRecord(tabId: UUID, surfaceId: UUID) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CMUX_UI_TEST_JUMP_UNREAD_PATH"], !path.isEmpty else { return }
        jumpUnreadFocusExpectation = (tabId: tabId, surfaceId: surfaceId)
        installJumpUnreadFocusObserverIfNeeded()
    }

    func recordJumpUnreadFocusIfExpected(tabId: UUID, surfaceId: UUID) {
        guard let expectation = jumpUnreadFocusExpectation else { return }
        guard expectation.tabId == tabId && expectation.surfaceId == surfaceId else { return }
        jumpUnreadFocusExpectation = nil
        recordJumpToUnreadFocus(tabId: tabId, surfaceId: surfaceId)
        if let jumpUnreadFocusObserver {
            NotificationCenter.default.removeObserver(jumpUnreadFocusObserver)
            self.jumpUnreadFocusObserver = nil
        }
    }

    private func installJumpUnreadFocusObserverIfNeeded() {
        guard jumpUnreadFocusObserver == nil else { return }
        jumpUnreadFocusObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusSurface,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
            guard let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else { return }
            self.recordJumpUnreadFocusIfExpected(tabId: tabId, surfaceId: surfaceId)
        }
    }

    private func writeJumpUnreadTestData(_ updates: [String: String]) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CMUX_UI_TEST_JUMP_UNREAD_PATH"], !path.isEmpty else { return }
        var payload = loadJumpUnreadTestData(at: path)
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func loadJumpUnreadTestData(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

    private func setupGotoSplitUITestIfNeeded() {
        guard !didSetupGotoSplitUITest else { return }
        didSetupGotoSplitUITest = true
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] == "1" else { return }
        guard tabManager != nil else { return }

        let useGhosttyConfig = env["CMUX_UI_TEST_GOTO_SPLIT_USE_GHOSTTY_CONFIG"] == "1"

        if useGhosttyConfig {
            // Keep the test hermetic: ensure the app does not accidentally pass using a persisted
            // KeyboardShortcutSettings override instead of the Ghostty config-trigger path.
            UserDefaults.standard.removeObject(forKey: KeyboardShortcutSettings.focusLeftKey)
            UserDefaults.standard.removeObject(forKey: KeyboardShortcutSettings.focusRightKey)
            UserDefaults.standard.removeObject(forKey: KeyboardShortcutSettings.focusUpKey)
            UserDefaults.standard.removeObject(forKey: KeyboardShortcutSettings.focusDownKey)
        } else {
            // For this UI test we want a letter-based shortcut (Cmd+Ctrl+H) to drive pane navigation,
            // since arrow keys can't be recorded by the shortcut recorder.
            KeyboardShortcutSettings.setShortcut(
                StoredShortcut(key: "h", command: true, shift: false, option: false, control: true),
                for: .focusLeft
            )
            KeyboardShortcutSettings.setShortcut(
                StoredShortcut(key: "l", command: true, shift: false, option: false, control: true),
                for: .focusRight
            )
            KeyboardShortcutSettings.setShortcut(
                StoredShortcut(key: "k", command: true, shift: false, option: false, control: true),
                for: .focusUp
            )
            KeyboardShortcutSettings.setShortcut(
                StoredShortcut(key: "j", command: true, shift: false, option: false, control: true),
                for: .focusDown
            )
        }

        installGotoSplitUITestFocusObserversIfNeeded()

        // On the VM, launching/initializing multiple windows can occasionally take longer than a
        // few seconds; keep the deadline generous so the test doesn't flake.
        let deadline = Date().addingTimeInterval(20.0)
        func hasMainTerminalWindow() -> Bool {
            NSApp.windows.contains { window in
                guard let raw = window.identifier?.rawValue else { return false }
                return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
            }
        }

        func runSetupWhenWindowReady() {
            guard Date() < deadline else {
                writeGotoSplitTestData(["setupError": "Timed out waiting for main window"])
                return
            }
            guard hasMainTerminalWindow() else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    runSetupWhenWindowReady()
                }
                return
            }
            guard let tabManager = self.tabManager else { return }

            let tab = tabManager.addTab()
            guard let initialPanelId = tab.focusedPanelId else {
                self.writeGotoSplitTestData(["setupError": "Missing initial panel id"])
                return
            }

            let requestedBrowserURL = env["CMUX_UI_TEST_GOTO_SPLIT_BROWSER_URL"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let url = requestedBrowserURL.flatMap { rawURL in
                guard !rawURL.isEmpty else { return nil }
                return URL(string: rawURL)
            } ?? URL(string: "https://example.com")
            guard let url else {
                self.writeGotoSplitTestData(["setupError": "Invalid browser URL"])
                return
            }
            guard let browserPanelId = tabManager.newBrowserSplit(
                tabId: tab.id,
                fromPanelId: initialPanelId,
                orientation: .horizontal,
                url: url
            ) else {
                self.writeGotoSplitTestData(["setupError": "Failed to create browser split"])
                return
            }

            self.focusWebViewForGotoSplitUITest(tab: tab, browserPanelId: browserPanelId)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard self != nil else { return }
            runSetupWhenWindowReady()
        }
    }

    private func setupBonsplitTabDragUITestIfNeeded() {
        guard !didSetupBonsplitTabDragUITest else { return }
        didSetupBonsplitTabDragUITest = true
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] == "1" else { return }
        guard tabManager != nil else { return }
        let startWithHiddenSidebar = env["CMUX_UI_TEST_BONSPLIT_START_WITH_HIDDEN_SIDEBAR"] == "1"

        let deadline = Date().addingTimeInterval(20.0)
        func hasMainTerminalWindow() -> Bool {
            NSApp.windows.contains { window in
                guard let raw = window.identifier?.rawValue else { return false }
                return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
            }
        }

        func runSetupWhenWindowReady() {
            guard Date() < deadline else {
                writeBonsplitTabDragUITestData(["setupError": "Timed out waiting for main window"])
                return
            }
            guard hasMainTerminalWindow() else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    runSetupWhenWindowReady()
                }
                return
            }
            if let mainWindow = NSApp.windows.first(where: { window in
                guard let raw = window.identifier?.rawValue else { return false }
                return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
            }) {
                let screenFrame = mainWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
                if let screenFrame {
                    let targetSize = NSSize(width: min(960, screenFrame.width - 80), height: min(720, screenFrame.height - 80))
                    let targetOrigin = NSPoint(
                        x: screenFrame.minX + 40,
                        y: screenFrame.maxY - 40 - targetSize.height
                    )
                    let targetFrame = NSRect(origin: targetOrigin, size: targetSize)
                    if !mainWindow.frame.equalTo(targetFrame) {
                        mainWindow.setFrame(targetFrame, display: true)
                    }
                }
            }
            guard let tabManager = self.tabManager,
                  let workspace = tabManager.selectedWorkspace ?? tabManager.tabs.first,
                  let alphaPanelId = workspace.focusedPanelId else {
                self.writeBonsplitTabDragUITestData(["setupError": "Missing initial workspace or panel"])
                return
            }

            let workspaceTitle = "UITest Workspace"
            let alphaTitle = "UITest Alpha"
            let betaTitle = "UITest Beta"
            tabManager.setCustomTitle(tabId: workspace.id, title: workspaceTitle)
            workspace.setPanelCustomTitle(panelId: alphaPanelId, title: alphaTitle)
            tabManager.newSurface()

            guard let betaPanelId = workspace.focusedPanelId, betaPanelId != alphaPanelId else {
                self.writeBonsplitTabDragUITestData(["setupError": "Failed to create second surface"])
                return
            }

            workspace.setPanelCustomTitle(panelId: betaPanelId, title: betaTitle)
            if startWithHiddenSidebar {
                self.sidebarState?.isVisible = false
            }
            self.writeBonsplitTabDragUITestData([
                "ready": "1",
                "sidebarVisible": startWithHiddenSidebar ? "0" : "1",
                "workspaceId": workspace.id.uuidString,
                "workspaceTitle": workspaceTitle,
                "alphaTitle": alphaTitle,
                "betaTitle": betaTitle,
                "alphaPanelId": alphaPanelId.uuidString,
                "betaPanelId": betaPanelId.uuidString,
            ])
            self.startBonsplitTabDragUITestRecorder(
                workspaceId: workspace.id,
                alphaPanelId: alphaPanelId,
                betaPanelId: betaPanelId
            )
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard self != nil else { return }
            runSetupWhenWindowReady()
        }
    }

    private func bonsplitTabDragUITestDataPath() -> String? {
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] == "1",
              let path = env["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH"],
              !path.isEmpty else {
            return nil
        }
        return path
    }

    private func startBonsplitTabDragUITestRecorder(
        workspaceId: UUID,
        alphaPanelId: UUID,
        betaPanelId: UUID
    ) {
        bonsplitTabDragUITestRecorder?.cancel()
        bonsplitTabDragUITestRecorder = nil

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.recordBonsplitTabDragUITestState(
                workspaceId: workspaceId,
                alphaPanelId: alphaPanelId,
                betaPanelId: betaPanelId
            )
        }
        bonsplitTabDragUITestRecorder = timer
        timer.resume()
    }

    private func recordBonsplitTabDragUITestState(
        workspaceId: UUID,
        alphaPanelId: UUID,
        betaPanelId: UUID
    ) {
        guard let tabManager else { return }
        guard let workspace = (tabManager.tabs.first { $0.id == workspaceId } ?? tabManager.selectedWorkspace ?? tabManager.tabs.first) else {
            return
        }

        let trackedPaneId = workspace.paneId(forPanelId: alphaPanelId)
            ?? workspace.paneId(forPanelId: betaPanelId)
            ?? workspace.bonsplitController.focusedPaneId
            ?? workspace.bonsplitController.allPaneIds.first
        guard let trackedPaneId else { return }

        let titles: [String] = workspace.bonsplitController.tabs(inPane: trackedPaneId).compactMap { tab in
            guard let panelId = workspace.panelIdFromSurfaceId(tab.id) else { return nil }
            return workspace.panelTitle(panelId: panelId)
        }
        let selectedTitle = workspace.bonsplitController.selectedTab(inPane: trackedPaneId)
            .flatMap { workspace.panelIdFromSurfaceId($0.id) }
            .flatMap { workspace.panelTitle(panelId: $0) } ?? ""

        writeBonsplitTabDragUITestData([
            "trackedPaneId": trackedPaneId.description,
            "trackedPaneTabTitles": titles.joined(separator: "|"),
            "trackedPaneTabCount": String(titles.count),
            "trackedPaneSelectedTitle": selectedTitle,
        ])
    }

    private func writeBonsplitTabDragUITestData(_ updates: [String: String]) {
        guard let path = bonsplitTabDragUITestDataPath() else { return }
        var payload = loadBonsplitTabDragUITestData(at: path)
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func loadBonsplitTabDragUITestData(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }
    private func isGotoSplitUITestRecordingEnabled() -> Bool {
        let env = ProcessInfo.processInfo.environment
        return env["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] == "1" || env["CMUX_UI_TEST_GOTO_SPLIT_RECORD_ONLY"] == "1"
    }

    private func gotoSplitUITestDataPath() -> String? {
        guard isGotoSplitUITestRecordingEnabled() else { return nil }
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CMUX_UI_TEST_GOTO_SPLIT_PATH"], !path.isEmpty else { return nil }
        return path
    }

    private func gotoSplitFindStateSnapshot(for workspace: Workspace) -> [String: String] {
        var updates: [String: String] = [
            "focusedPaneId": workspace.bonsplitController.focusedPaneId?.description ?? ""
        ]

        if let focusedPanelId = workspace.focusedPanelId {
            updates["focusedPanelId"] = focusedPanelId.uuidString
            if let terminal = workspace.terminalPanel(for: focusedPanelId) {
                updates["focusedPanelKind"] = "terminal"
                updates["focusedTerminalFindNeedle"] = terminal.searchState?.needle ?? ""
                updates["focusedBrowserFindNeedle"] = ""
            } else if let browser = workspace.browserPanel(for: focusedPanelId) {
                updates["focusedPanelKind"] = "browser"
                updates["focusedBrowserFindNeedle"] = browser.searchState?.needle ?? ""
                updates["focusedTerminalFindNeedle"] = ""
            } else {
                updates["focusedPanelKind"] = "other"
                updates["focusedTerminalFindNeedle"] = ""
                updates["focusedBrowserFindNeedle"] = ""
            }
        } else {
            updates["focusedPanelId"] = ""
            updates["focusedPanelKind"] = "none"
            updates["focusedTerminalFindNeedle"] = ""
            updates["focusedBrowserFindNeedle"] = ""
        }

        let terminalWithFind = workspace.panels.values
            .compactMap { $0 as? TerminalPanel }
            .first(where: { $0.searchState != nil })
        updates["terminalFindPanelId"] = terminalWithFind?.id.uuidString ?? ""
        updates["terminalFindNeedle"] = terminalWithFind?.searchState?.needle ?? ""
        updates["terminalFindVisible"] = terminalWithFind == nil ? "false" : "true"

        let browserWithFind = workspace.panels.values
            .compactMap { $0 as? BrowserPanel }
            .first(where: { $0.searchState != nil })
        updates["browserFindPanelId"] = browserWithFind?.id.uuidString ?? ""
        updates["browserFindNeedle"] = browserWithFind?.searchState?.needle ?? ""
        updates["browserFindSelected"] = browserWithFind?.searchState?.selected.map {
            String($0 + 1)
        } ?? ""
        updates["browserFindTotal"] = browserWithFind?.searchState?.total.map(String.init) ?? ""
        updates["browserFindVisible"] = browserWithFind == nil ? "false" : "true"

        return updates
    }

    private func focusWebViewForGotoSplitUITest(tab: Workspace, browserPanelId: UUID) {
        guard let browserPanel = tab.browserPanel(for: browserPanelId) else {
            writeGotoSplitTestData([
                "webViewFocused": "false",
                "setupError": "Browser panel missing"
            ])
            return
        }

        var resolved = false
        var observers: [NSObjectProtocol] = []
        var panelsCancellable: AnyCancellable?

        func cleanup() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            panelsCancellable?.cancel()
        }

        func recordFocusedState() {
            guard !resolved else { return }
            guard let panel = tab.browserPanel(for: browserPanelId) else {
                resolved = true
                cleanup()
                writeGotoSplitTestData([
                    "webViewFocused": "false",
                    "setupError": "Browser panel missing"
                ])
                return
            }

            tab.focusPanel(browserPanelId)

            guard isWebViewFocused(panel),
                  let (browserPaneId, terminalPaneId) = paneIdsForGotoSplitUITest(
                    tab: tab,
                    browserPanelId: browserPanelId
                  ) else {
                return
            }

            resolved = true
            cleanup()
            self.startGotoSplitUITestRecorder(browserPanelId: browserPanelId)
            writeGotoSplitTestData([
                "browserPanelId": browserPanelId.uuidString,
                "browserPaneId": browserPaneId.description,
                "terminalPaneId": terminalPaneId.description,
                "initialPaneCount": String(tab.bonsplitController.allPaneIds.count),
                "focusedPaneId": tab.bonsplitController.focusedPaneId?.description ?? "",
                "ghosttyGotoSplitLeftShortcut": ghosttyGotoSplitLeftShortcut?.displayString ?? "",
                "ghosttyGotoSplitRightShortcut": ghosttyGotoSplitRightShortcut?.displayString ?? "",
                "ghosttyGotoSplitUpShortcut": ghosttyGotoSplitUpShortcut?.displayString ?? "",
                "ghosttyGotoSplitDownShortcut": ghosttyGotoSplitDownShortcut?.displayString ?? "",
                "webViewFocused": "true"
            ])
            if ProcessInfo.processInfo.environment["CMUX_UI_TEST_GOTO_SPLIT_INPUT_SETUP"] == "1" {
                setupFocusedInputForGotoSplitUITest(panel: panel)
            }
        }

        observers.append(NotificationCenter.default.addObserver(
            forName: .browserDidBecomeFirstResponderWebView,
            object: nil,
            queue: .main
        ) { _ in
            recordFocusedState()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusSurface,
            object: nil,
            queue: .main
        ) { note in
            guard let surfaceId = note.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID,
                  surfaceId == browserPanelId else { return }
            recordFocusedState()
        })
        panelsCancellable = tab.$panels
            .map { _ in () }
            .sink { _ in recordFocusedState() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
            guard let self else { return }
            if !resolved {
                cleanup()
                self.writeGotoSplitTestData([
                    "webViewFocused": "false",
                    "setupError": "Timed out waiting for WKWebView focus"
                ])
            }
        }

        recordFocusedState()
    }

    private func startGotoSplitUITestRecorder(browserPanelId: UUID) {
        guard isGotoSplitUITestRecordingEnabled() else { return }
        gotoSplitUITestRecorder?.cancel()
        gotoSplitUITestRecorder = nil

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.recordGotoSplitUITestState(browserPanelId: browserPanelId)
        }
        gotoSplitUITestRecorder = timer
        timer.resume()
    }

    private func recordGotoSplitUITestState(browserPanelId: UUID) {
        guard let tabManager,
              let workspace = tabManager.selectedWorkspace,
              let browserPanel = workspace.browserPanel(for: browserPanelId) else {
            return
        }

        var updates = gotoSplitFindStateSnapshot(for: workspace)
        updates["browserPageTitle"] = browserPanel.webView.title?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        updates["browserPageURL"] = browserPanel.preferredURLStringForOmnibar() ?? ""
        writeGotoSplitTestData(updates)
    }

    private func isWebViewFocused(_ panel: BrowserPanel) -> Bool {
        guard let window = panel.webView.window else { return false }
        guard let fr = window.firstResponder as? NSView else { return false }
        return fr.isDescendant(of: panel.webView)
    }

    private func paneIdsForGotoSplitUITest(tab: Workspace, browserPanelId: UUID) -> (browser: PaneID, terminal: PaneID)? {
        let paneIds = tab.bonsplitController.allPaneIds
        guard paneIds.count >= 2 else { return nil }

        var browserPane: PaneID?
        var terminalPane: PaneID?
        for paneId in paneIds {
            guard let selected = tab.bonsplitController.selectedTab(inPane: paneId),
                  let panelId = tab.panelIdFromSurfaceId(selected.id) else { continue }
            if panelId == browserPanelId {
                browserPane = paneId
            } else if terminalPane == nil {
                terminalPane = paneId
            }
        }

        guard let browserPane, let terminalPane else { return nil }
        return (browserPane, terminalPane)
    }

    private func installGotoSplitUITestFocusObserversIfNeeded() {
        guard gotoSplitUITestObservers.isEmpty else { return }

        gotoSplitUITestObservers.append(NotificationCenter.default.addObserver(
            forName: .browserFocusAddressBar,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let panelId = notification.object as? UUID else { return }
            self.recordGotoSplitUITestWebViewFocus(panelId: panelId, key: "webViewFocusedAfterAddressBarFocus")
            self.recordGotoSplitUITestActiveElement(panelId: panelId, keyPrefix: "addressBarFocus")
        })

        gotoSplitUITestObservers.append(NotificationCenter.default.addObserver(
            forName: .browserDidExitAddressBar,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let panelId = notification.object as? UUID else { return }
            self.recordGotoSplitUITestWebViewFocus(panelId: panelId, key: "webViewFocusedAfterAddressBarExit")
            self.recordGotoSplitUITestActiveElement(panelId: panelId, keyPrefix: "addressBarExit")
        })
    }

    private func recordGotoSplitUITestWebViewFocus(panelId: UUID, key: String) {
        guard let tabManager,
              let tab = tabManager.selectedWorkspace,
              let panel = tab.browserPanel(for: panelId) else {
            return
        }

        guard key.contains("Exit") else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.writeGotoSplitTestData([
                    key: self.isWebViewFocused(panel) ? "true" : "false",
                    "\(key)PanelId": panelId.uuidString
                ])
            }
            return
        }

        var resolved = false
        var observers: [NSObjectProtocol] = []
        var panelsCancellable: AnyCancellable?

        func cleanup() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            panelsCancellable?.cancel()
            panelsCancellable = nil
        }

        @MainActor
        func finish(with focused: Bool) {
            guard !resolved else { return }
            resolved = true
            cleanup()
            self.writeGotoSplitTestData([
                key: focused ? "true" : "false",
                "\(key)PanelId": panelId.uuidString
            ])
        }

        @MainActor
        func evaluate() {
            guard !resolved,
                  let currentTabManager = self.tabManager,
                  let currentTab = currentTabManager.selectedWorkspace,
                  let currentPanel = currentTab.browserPanel(for: panelId) else {
                return
            }
            guard self.isWebViewFocused(currentPanel) else { return }
            finish(with: true)
        }

        observers.append(NotificationCenter.default.addObserver(
            forName: .browserDidBecomeFirstResponderWebView,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard notification.object as? WKWebView === panel.webView else { return }
            Task { @MainActor in evaluate() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusSurface,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID,
                  surfaceId == panelId else { return }
            Task { @MainActor in evaluate() }
        })
        panelsCancellable = tab.$panels
            .map { _ in () }
            .sink { _ in
                Task { @MainActor in evaluate() }
            }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard !resolved else { return }
                let focused = (self.tabManager?.selectedWorkspace?.browserPanel(for: panelId)).map(self.isWebViewFocused) ?? false
                finish(with: focused)
            }
        }
        Task { @MainActor in evaluate() }
    }

    private func javaScriptLiteral(_ value: String?) -> String {
        guard let value else { return "null" }
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let arrayLiteral = String(data: data, encoding: .utf8),
              arrayLiteral.count >= 2 else {
            return "null"
        }
        return String(arrayLiteral.dropFirst().dropLast())
    }

    private func setupFocusedInputForGotoSplitUITest(panel: BrowserPanel) {
        let script = """
        (() => {
          const snapshot = () => {
            const active = document.activeElement;
            return {
              focused: false,
              id: "",
              secondaryId: "",
              secondaryCenterX: -1,
              secondaryCenterY: -1,
              activeId: active && typeof active.id === "string" ? active.id : "",
              activeTag: active && active.tagName ? active.tagName.toLowerCase() : "",
              trackerInstalled: window.__cmuxAddressBarFocusTrackerInstalled === true,
              trackedStateId:
                window.__cmuxAddressBarFocusState &&
                typeof window.__cmuxAddressBarFocusState.id === "string"
                  ? window.__cmuxAddressBarFocusState.id
                  : "",
              readyState: String(document.readyState || "")
            };
          };
          const seed = () => {
            const ensureInput = (id, value) => {
              const existing = document.getElementById(id);
              const input = (existing && existing.tagName && existing.tagName.toLowerCase() === "input")
                ? existing
                : (() => {
                    const created = document.createElement("input");
                    created.id = id;
                    created.type = "text";
                    created.value = value;
                    return created;
                  })();
              input.autocapitalize = "off";
              input.autocomplete = "off";
              input.spellcheck = false;
              input.style.display = "block";
              input.style.width = "100%";
              input.style.margin = "0";
              input.style.padding = "8px 10px";
              input.style.border = "1px solid #5f6368";
              input.style.borderRadius = "6px";
              input.style.boxSizing = "border-box";
              input.style.fontSize = "14px";
              input.style.fontFamily = "system-ui, -apple-system, sans-serif";
              input.style.background = "white";
              input.style.color = "black";
              return input;
            };

            let container = document.getElementById("cmux-ui-test-focus-container");
            if (!container || !container.tagName || container.tagName.toLowerCase() !== "div") {
              container = document.createElement("div");
              container.id = "cmux-ui-test-focus-container";
              document.body.appendChild(container);
            }
            container.style.position = "fixed";
            container.style.left = "24px";
            container.style.top = "24px";
            container.style.width = "min(520px, calc(100vw - 48px))";
            container.style.display = "grid";
            container.style.rowGap = "12px";
            container.style.padding = "12px";
            container.style.background = "rgba(255,255,255,0.92)";
            container.style.border = "1px solid rgba(95,99,104,0.55)";
            container.style.borderRadius = "8px";
            container.style.boxShadow = "0 2px 10px rgba(0,0,0,0.2)";
            container.style.zIndex = "2147483647";

            const input = ensureInput("cmux-ui-test-focus-input", "cmux-ui-focus-primary");
            const secondaryInput = ensureInput("cmux-ui-test-focus-input-secondary", "cmux-ui-focus-secondary");
            if (input.parentElement !== container) {
              container.appendChild(input);
            }
            if (secondaryInput.parentElement !== container) {
              container.appendChild(secondaryInput);
            }

            input.focus({ preventScroll: true });
            if (typeof input.setSelectionRange === "function") {
              const end = input.value.length;
              input.setSelectionRange(end, end);
            }

            let trackedFocusId = input.getAttribute("data-cmux-addressbar-focus-id");
            if (!trackedFocusId) {
              trackedFocusId = "cmux-ui-test-focus-input-tracked";
              input.setAttribute("data-cmux-addressbar-focus-id", trackedFocusId);
            }
            const selectionStart = typeof input.selectionStart === "number" ? input.selectionStart : null;
            const selectionEnd = typeof input.selectionEnd === "number" ? input.selectionEnd : null;
            if (
              !window.__cmuxAddressBarFocusState ||
              typeof window.__cmuxAddressBarFocusState.id !== "string" ||
              window.__cmuxAddressBarFocusState.id !== trackedFocusId
            ) {
              window.__cmuxAddressBarFocusState = { id: trackedFocusId, selectionStart, selectionEnd };
            }

            const secondaryRect = secondaryInput.getBoundingClientRect();
            const viewportWidth = Math.max(Number(window.innerWidth) || 0, 1);
            const viewportHeight = Math.max(Number(window.innerHeight) || 0, 1);
            const secondaryCenterX = Math.min(
              0.98,
              Math.max(0.02, (secondaryRect.left + (secondaryRect.width / 2)) / viewportWidth)
            );
            const secondaryCenterY = Math.min(
              0.98,
              Math.max(0.02, (secondaryRect.top + (secondaryRect.height / 2)) / viewportHeight)
            );
            const active = document.activeElement;
            return {
              focused: active === input,
              id: input.id || "",
              secondaryId: secondaryInput.id || "",
              secondaryCenterX,
              secondaryCenterY,
              activeId: active && typeof active.id === "string" ? active.id : "",
              activeTag: active && active.tagName ? active.tagName.toLowerCase() : "",
              trackerInstalled: window.__cmuxAddressBarFocusTrackerInstalled === true,
              trackedStateId:
                window.__cmuxAddressBarFocusState &&
                typeof window.__cmuxAddressBarFocusState.id === "string"
                  ? window.__cmuxAddressBarFocusState.id
                  : "",
              readyState: String(document.readyState || "")
            };
          };
          const ready = () =>
            window.__cmuxAddressBarFocusTrackerInstalled === true &&
            String(document.readyState || "") === "complete";

          if (ready()) {
            try {
              return seed();
            } catch (_) {
              return snapshot();
            }
          }

          return new Promise((resolve) => {
            let finished = false;
            let observer = null;
            const cleanups = [];
            const finish = (value) => {
              if (finished) return;
              finished = true;
              if (observer) observer.disconnect();
              for (const cleanup of cleanups) {
                try { cleanup(); } catch (_) {}
              }
              resolve(value);
            };
            const maybeFinish = () => {
              if (!ready()) return;
              try {
                finish(seed());
              } catch (_) {
                finish(snapshot());
              }
            };
            const addListener = (target, eventName, options) => {
              if (!target || typeof target.addEventListener !== "function") return;
              const handler = () => maybeFinish();
              target.addEventListener(eventName, handler, options);
              cleanups.push(() => target.removeEventListener(eventName, handler, options));
            };
            try {
              observer = new MutationObserver(() => maybeFinish());
              observer.observe(document.documentElement || document, {
                childList: true,
                subtree: true,
                attributes: true,
                characterData: true
              });
            } catch (_) {}
            addListener(document, "readystatechange", true);
            addListener(window, "load", true);
            const timeoutId = window.setTimeout(() => finish(snapshot()), 4000);
            cleanups.push(() => window.clearTimeout(timeoutId));
            maybeFinish();
          });
        })();
        """

        panel.webView.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self else { return }
            let payload = result as? [String: Any]
            let focused = (payload?["focused"] as? Bool) ?? false
            let inputId = (payload?["id"] as? String) ?? ""
            let secondaryInputId = (payload?["secondaryId"] as? String) ?? ""
            let secondaryCenterX = (payload?["secondaryCenterX"] as? NSNumber)?.doubleValue ?? -1
            let secondaryCenterY = (payload?["secondaryCenterY"] as? NSNumber)?.doubleValue ?? -1
            let activeId = (payload?["activeId"] as? String) ?? ""
            let trackerInstalled = (payload?["trackerInstalled"] as? Bool) ?? false
            let trackedStateId = (payload?["trackedStateId"] as? String) ?? ""
            let readyState = (payload?["readyState"] as? String) ?? ""
            var secondaryClickOffsetX = -1.0
            var secondaryClickOffsetY = -1.0
            if let window = panel.webView.window {
                let webFrame = panel.webView.convert(panel.webView.bounds, to: nil)
                let contentHeight = Double(window.contentView?.bounds.height ?? 0)
                if webFrame.width > 1,
                   webFrame.height > 1,
                   contentHeight > 1,
                   secondaryCenterX > 0,
                   secondaryCenterX < 1,
                   secondaryCenterY > 0,
                   secondaryCenterY < 1 {
                    let xInContent = Double(webFrame.minX) + (secondaryCenterX * Double(webFrame.width))
                    let yFromTopInWeb = secondaryCenterY * Double(webFrame.height)
                    let yInContent = Double(webFrame.maxY) - yFromTopInWeb
                    let yFromTopInContent = contentHeight - yInContent
                    let titlebarHeight = max(0, Double(window.frame.height) - contentHeight)
                    secondaryClickOffsetX = xInContent
                    secondaryClickOffsetY = titlebarHeight + yFromTopInContent
                }
            }
            if focused,
               !inputId.isEmpty,
               !secondaryInputId.isEmpty,
               inputId == activeId,
               trackerInstalled,
               !trackedStateId.isEmpty,
               secondaryCenterX > 0,
               secondaryCenterX < 1,
               secondaryCenterY > 0,
               secondaryCenterY < 1,
               secondaryClickOffsetX > 0,
               secondaryClickOffsetY > 0 {
                self.writeGotoSplitTestData([
                    "webInputFocusSeeded": "true",
                    "webInputFocusElementId": inputId,
                    "webInputFocusSecondaryElementId": secondaryInputId,
                    "webInputFocusSecondaryCenterX": "\(secondaryCenterX)",
                    "webInputFocusSecondaryCenterY": "\(secondaryCenterY)",
                    "webInputFocusSecondaryClickOffsetX": "\(secondaryClickOffsetX)",
                    "webInputFocusSecondaryClickOffsetY": "\(secondaryClickOffsetY)",
                    "webInputFocusActiveElementId": activeId,
                    "webInputFocusTrackerInstalled": trackerInstalled ? "true" : "false",
                    "webInputFocusTrackedStateId": trackedStateId,
                    "webInputFocusReadyState": readyState
                ])
                return
            }
            self.writeGotoSplitTestData([
                "webInputFocusSeeded": "false",
                "setupError": "Timed out focusing page input for omnibar restore test"
            ])
        }
    }

    private func recordGotoSplitUITestActiveElement(panelId: UUID, keyPrefix: String) {
        guard let tabManager,
              let tab = tabManager.selectedWorkspace,
              let panel = tab.browserPanel(for: panelId) else {
            return
        }

        let expectedInputId = keyPrefix == "addressBarExit" ? gotoSplitUITestExpectedInputId() : nil
        let capture: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.evaluateGotoSplitUITestActiveElement(
                panel: panel,
                awaitingInputId: expectedInputId
            ) { snapshot in
                self.writeGotoSplitTestData([
                    "\(keyPrefix)PanelId": panelId.uuidString,
                    "\(keyPrefix)ActiveElementId": snapshot["id"] ?? "",
                    "\(keyPrefix)ActiveElementTag": snapshot["tag"] ?? "",
                    "\(keyPrefix)ActiveElementType": snapshot["type"] ?? "",
                    "\(keyPrefix)ActiveElementEditable": snapshot["editable"] ?? "false",
                    "\(keyPrefix)TrackedFocusStateId": snapshot["trackedFocusStateId"] ?? "",
                    "\(keyPrefix)FocusTrackerInstalled": snapshot["focusTrackerInstalled"] ?? "false"
                ])
            }
        }

        if expectedInputId == nil {
            DispatchQueue.main.async {
                Task { @MainActor in capture() }
            }
        } else {
            Task { @MainActor in capture() }
        }
    }

    private func evaluateGotoSplitUITestActiveElement(
        panel: BrowserPanel,
        awaitingInputId: String? = nil,
        completion: @escaping ([String: String]) -> Void
    ) {
        let expectedInputIdLiteral = javaScriptLiteral(awaitingInputId)
        let script = """
        (() => {
          const expectedInputId = \(expectedInputIdLiteral);
          const snapshot = () => {
            try {
              const active = document.activeElement;
              if (!active) {
                return {
                  id: "",
                  tag: "",
                  type: "",
                  editable: "false",
                  trackedFocusStateId: "",
                  focusTrackerInstalled: window.__cmuxAddressBarFocusTrackerInstalled === true ? "true" : "false"
                };
              }
              const tag = (active.tagName || "").toLowerCase();
              const type = (active.type || "").toLowerCase();
              const editable =
                !!active.isContentEditable ||
                tag === "textarea" ||
                (tag === "input" && type !== "hidden");
              return {
                id: typeof active.id === "string" ? active.id : "",
                tag,
                type,
                editable: editable ? "true" : "false",
                trackedFocusStateId:
                  window.__cmuxAddressBarFocusState &&
                  typeof window.__cmuxAddressBarFocusState.id === "string"
                    ? window.__cmuxAddressBarFocusState.id
                    : "",
                focusTrackerInstalled:
                  window.__cmuxAddressBarFocusTrackerInstalled === true ? "true" : "false"
              };
            } catch (_) {
              return {
                id: "",
                tag: "",
                type: "",
                editable: "false",
                trackedFocusStateId: "",
                focusTrackerInstalled: "false"
              };
            }
          };
          const matchesExpectation = (state) =>
            !expectedInputId || (typeof expectedInputId === "string" && state.id === expectedInputId);

          const initial = snapshot();
          if (matchesExpectation(initial)) {
            return initial;
          }

          return new Promise((resolve) => {
            let finished = false;
            let observer = null;
            const cleanups = [];
            const finish = (value) => {
              if (finished) return;
              finished = true;
              if (observer) observer.disconnect();
              for (const cleanup of cleanups) {
                try { cleanup(); } catch (_) {}
              }
              resolve(value);
            };
            const maybeFinish = () => {
              const state = snapshot();
              if (matchesExpectation(state)) {
                finish(state);
              }
            };
            const addListener = (target, eventName, options) => {
              if (!target || typeof target.addEventListener !== "function") return;
              const handler = () => maybeFinish();
              target.addEventListener(eventName, handler, options);
              cleanups.push(() => target.removeEventListener(eventName, handler, options));
            };
            try {
              observer = new MutationObserver(() => maybeFinish());
              observer.observe(document.documentElement || document, {
                childList: true,
                subtree: true,
                attributes: true,
                characterData: true
              });
            } catch (_) {}
            addListener(document, "focusin", true);
            addListener(document, "focusout", true);
            addListener(document, "selectionchange", true);
            addListener(document, "readystatechange", true);
            addListener(window, "load", true);
            const timeoutId = window.setTimeout(() => finish(snapshot()), 1500);
            cleanups.push(() => window.clearTimeout(timeoutId));
            maybeFinish();
          });
        })();
        """

        panel.webView.evaluateJavaScript(script) { result, _ in
            let payload = result as? [String: Any]
            completion([
                "id": (payload?["id"] as? String) ?? "",
                "tag": (payload?["tag"] as? String) ?? "",
                "type": (payload?["type"] as? String) ?? "",
                "editable": (payload?["editable"] as? String) ?? "false",
                "trackedFocusStateId": (payload?["trackedFocusStateId"] as? String) ?? "",
                "focusTrackerInstalled": (payload?["focusTrackerInstalled"] as? String) ?? "false"
            ])
        }
    }

    private func gotoSplitUITestExpectedInputId() -> String? {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CMUX_UI_TEST_GOTO_SPLIT_PATH"], !path.isEmpty else { return nil }
        return loadGotoSplitTestData(at: path)["webInputFocusElementId"]
    }

    private func recordGotoSplitMoveIfNeeded(direction: NavigationDirection) {
        guard isGotoSplitUITestRecordingEnabled() else { return }
        guard let tabManager, let workspace = tabManager.selectedWorkspace else { return }

        let directionValue: String
        switch direction {
        case .left:
            directionValue = "left"
        case .right:
            directionValue = "right"
        case .up:
            directionValue = "up"
        case .down:
            directionValue = "down"
        }

        var updates = gotoSplitFindStateSnapshot(for: workspace)
        updates["lastMoveDirection"] = directionValue
        writeGotoSplitTestData(updates)
    }

    private func recordGotoSplitSplitIfNeeded(direction: SplitDirection) {
        guard isGotoSplitUITestRecordingEnabled() else { return }
        guard let workspace = tabManager?.selectedWorkspace else { return }

        let directionValue: String
        switch direction {
        case .left:
            directionValue = "left"
        case .right:
            directionValue = "right"
        case .up:
            directionValue = "up"
        case .down:
            directionValue = "down"
        }

        var updates = gotoSplitFindStateSnapshot(for: workspace)
        updates["lastSplitDirection"] = directionValue
        updates["paneCountAfterSplit"] = String(workspace.bonsplitController.allPaneIds.count)
        writeGotoSplitTestData(updates)
    }

    private func recordGotoSplitZoomIfNeeded() {
        guard isGotoSplitUITestRecordingEnabled() else { return }
        guard let workspace = tabManager?.selectedWorkspace else { return }

        func snapshot(for workspace: Workspace) -> ([String: String], Bool) {
            let browserPanel = workspace.panels.values.compactMap { $0 as? BrowserPanel }.first
            let otherTerminal = workspace.panels.values.compactMap { $0 as? TerminalPanel }.first
            let browserSnapshot = browserPanel.flatMap {
                BrowserWindowPortalRegistry.debugSnapshot(for: $0.webView)
            }

            var updates = self.gotoSplitFindStateSnapshot(for: workspace)
            updates["splitZoomedAfterToggle"] = workspace.bonsplitController.isSplitZoomed ? "true" : "false"
            updates["zoomedPaneIdAfterToggle"] = workspace.bonsplitController.zoomedPaneId?.description ?? ""
            updates["browserPanelIdAfterToggle"] = browserPanel?.id.uuidString ?? ""
            updates["browserContainerHiddenAfterToggle"] = browserSnapshot.map { $0.containerHidden ? "true" : "false" } ?? ""
            updates["browserVisibleFlagAfterToggle"] = browserSnapshot.map { $0.visibleInUI ? "true" : "false" } ?? ""
            updates["browserFrameAfterToggle"] = browserSnapshot.map {
                String(
                    format: "%.1f,%.1f %.1fx%.1f",
                    $0.frameInWindow.origin.x,
                    $0.frameInWindow.origin.y,
                    $0.frameInWindow.size.width,
                    $0.frameInWindow.size.height
                )
            } ?? ""
            updates["otherTerminalPanelIdAfterToggle"] = otherTerminal?.id.uuidString ?? ""
            updates["otherTerminalHostHiddenAfterToggle"] = otherTerminal.map { $0.hostedView.isHidden ? "true" : "false" } ?? ""
            updates["otherTerminalVisibleFlagAfterToggle"] = otherTerminal.map { $0.hostedView.debugPortalVisibleInUI ? "true" : "false" } ?? ""
            updates["otherTerminalFrameAfterToggle"] = otherTerminal.map {
                let frame = $0.hostedView.debugPortalFrameInWindow
                return String(
                    format: "%.1f,%.1f %.1fx%.1f",
                    frame.origin.x,
                    frame.origin.y,
                    frame.size.width,
                    frame.size.height
                )
            } ?? ""

            let settled: Bool = {
                if workspace.bonsplitController.isSplitZoomed {
                    if let focusedPanelId = workspace.focusedPanelId,
                       workspace.terminalPanel(for: focusedPanelId) != nil {
                        guard let browserSnapshot else { return false }
                        return browserSnapshot.containerHidden && !browserSnapshot.visibleInUI
                    }
                    guard let otherTerminal else { return true }
                    return otherTerminal.hostedView.isHidden && !otherTerminal.hostedView.debugPortalVisibleInUI
                }
                let browserRestored = browserSnapshot.map { !$0.containerHidden && $0.visibleInUI } ?? true
                let terminalRestored = otherTerminal.map {
                    !$0.hostedView.isHidden && $0.hostedView.debugPortalVisibleInUI
                } ?? true
                return browserRestored && terminalRestored
            }()

            return (updates, settled)
        }

        var resolved = false
        var observers: [NSObjectProtocol] = []
        var panelsCancellable: AnyCancellable?

        func cleanup() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            panelsCancellable?.cancel()
            panelsCancellable = nil
        }

        @MainActor
        func finish(with updates: [String: String]) {
            guard !resolved else { return }
            resolved = true
            cleanup()
            self.writeGotoSplitTestData(updates)
        }

        @MainActor
        func evaluate() {
            guard !resolved, let currentWorkspace = self.tabManager?.selectedWorkspace else { return }
            let (updates, settled) = snapshot(for: currentWorkspace)
            guard settled else { return }
            finish(with: updates)
        }

        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in evaluate() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .terminalSurfaceHostedViewDidMoveToWindow,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in evaluate() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in evaluate() }
        })
        panelsCancellable = workspace.$panels
            .map { _ in () }
            .sink { _ in
                Task { @MainActor in evaluate() }
            }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard !resolved, let currentWorkspace = self.tabManager?.selectedWorkspace else { return }
                finish(with: snapshot(for: currentWorkspace).0)
            }
        }
        Task { @MainActor in evaluate() }
    }

    private func writeGotoSplitTestData(_ updates: [String: String]) {
        guard let path = gotoSplitUITestDataPath() else { return }
        var payload = loadGotoSplitTestData(at: path)
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func loadGotoSplitTestData(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

    private func setupMultiWindowNotificationsUITestIfNeeded() {
        guard !didSetupMultiWindowNotificationsUITest else { return }
        didSetupMultiWindowNotificationsUITest = true

        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_SETUP"] == "1" else { return }
        guard let path = env["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_PATH"], !path.isEmpty else { return }

        try? FileManager.default.removeItem(atPath: path)

        func waitForContexts(minCount: Int, _ completion: @escaping () -> Void) {
            let isReady = {
                self.mainWindowContexts.count >= minCount &&
                    self.mainWindowContexts.values.allSatisfy { $0.window != nil }
            }
            guard !isReady() else {
                completion()
                return
            }

            var resolved = false
            var observer: NSObjectProtocol?
            let finish = {
                guard !resolved else { return }
                resolved = true
                if let observer {
                    NotificationCenter.default.removeObserver(observer)
                }
                completion()
            }
            observer = NotificationCenter.default.addObserver(
                forName: .mainWindowContextsDidChange,
                object: self,
                queue: .main
            ) { _ in
                if isReady() {
                    finish()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
                if isReady() {
                    finish()
                } else if let observer, !resolved {
                    NotificationCenter.default.removeObserver(observer)
                }
            }
        }

        func waitForSurfaceId(
            on tabManager: TabManager,
            tabId: UUID,
            timeout: TimeInterval = 8.0,
            _ completion: @escaping (UUID) -> Void
        ) {
            func resolvedSurfaceId() -> UUID? {
                if let surfaceId = tabManager.focusedPanelId(for: tabId) {
                    return surfaceId
                }

                guard let workspace = tabManager.tabs.first(where: { $0.id == tabId }) else {
                    return nil
                }

                if let terminalPanelId = workspace.focusedTerminalPanel?.id {
                    return terminalPanelId
                }

                if let terminalPanelId = workspace.terminalPanelForConfigInheritance()?.id {
                    return terminalPanelId
                }

                return workspace.panels.values
                    .compactMap { ($0 as? TerminalPanel)?.id }
                    .sorted(by: { $0.uuidString < $1.uuidString })
                    .first
            }

            if let surfaceId = resolvedSurfaceId() {
                completion(surfaceId)
                return
            }

            var resolved = false
            var focusObserver: NSObjectProtocol?
            var surfaceReadyObserver: NSObjectProtocol?
            var tabsCancellable: AnyCancellable?
            var panelsCancellable: AnyCancellable?
            var observedWorkspaceId: UUID?

            func cleanup() {
                if let focusObserver {
                    NotificationCenter.default.removeObserver(focusObserver)
                }
                if let surfaceReadyObserver {
                    NotificationCenter.default.removeObserver(surfaceReadyObserver)
                }
                tabsCancellable?.cancel()
                panelsCancellable?.cancel()
            }

            func attemptResolve() {
                guard !resolved else { return }
                if let workspace = tabManager.tabs.first(where: { $0.id == tabId }),
                   observedWorkspaceId != workspace.id {
                    observedWorkspaceId = workspace.id
                    panelsCancellable?.cancel()
                    panelsCancellable = workspace.$panels
                        .map { _ in () }
                        .sink { _ in attemptResolve() }
                }
                if let surfaceId = resolvedSurfaceId() {
                    resolved = true
                    cleanup()
                    completion(surfaceId)
                }
            }

            tabsCancellable = tabManager.$tabs
                .map { _ in () }
                .sink { _ in attemptResolve() }
            focusObserver = NotificationCenter.default.addObserver(
                forName: .ghosttyDidFocusSurface,
                object: nil,
                queue: .main
            ) { note in
                guard let candidateTabId = note.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                      candidateTabId == tabId else { return }
                attemptResolve()
            }
            surfaceReadyObserver = NotificationCenter.default.addObserver(
                forName: .terminalSurfaceDidBecomeReady,
                object: nil,
                queue: .main
            ) { note in
                guard let workspaceId = note.userInfo?["workspaceId"] as? UUID,
                      workspaceId == tabId else { return }
                attemptResolve()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                if !resolved {
                    cleanup()
                }
            }
            attemptResolve()
        }

        waitForContexts(minCount: 1) { [weak self] in
            guard let self else { return }
            guard let window1 = self.mainWindowContexts.values.first else { return }
            guard let tabId1 = window1.tabManager.selectedTabId ?? window1.tabManager.tabs.first?.id else { return }

            // Create a second main terminal window.
            self.openNewMainWindow(nil)

            waitForContexts(minCount: 2) { [weak self] in
                guard let self else { return }
                let contexts = Array(self.mainWindowContexts.values)
                guard let window2 = contexts.first(where: { $0.windowId != window1.windowId }) else { return }
                guard let tabId2 = window2.tabManager.selectedTabId ?? window2.tabManager.tabs.first?.id else { return }
                waitForSurfaceId(on: window1.tabManager, tabId: tabId1) { [weak self] surfaceId1 in
                    guard let self else { return }
                    waitForSurfaceId(on: window2.tabManager, tabId: tabId2) { [weak self] surfaceId2 in
                    guard let self else { return }
                    guard let store = self.notificationStore else { return }

                    // Ensure the target window is currently showing the Notifications overlay,
                    // so opening a notification must switch it back to the terminal UI.
                    window2.sidebarSelectionState.selection = .notifications

                    // Create notifications for both windows. Ensure W2 isn't suppressed just because it's focused.
                    let prevOverride = AppFocusState.overrideIsFocused
                    AppFocusState.overrideIsFocused = false
                    store.addNotification(tabId: tabId2, surfaceId: nil, title: "W2", subtitle: "multiwindow", body: "")
                    AppFocusState.overrideIsFocused = prevOverride

                    // Insert after W2 so it becomes "latest unread" (first in list).
                    store.addNotification(tabId: tabId1, surfaceId: nil, title: "W1", subtitle: "multiwindow", body: "")

                    let notif1 = store.notifications.first(where: { $0.tabId == tabId1 && $0.title == "W1" })
                    let notif2 = store.notifications.first(where: { $0.tabId == tabId2 && $0.title == "W2" })

                    self.writeMultiWindowNotificationTestData([
                        "window1Id": window1.windowId.uuidString,
                        "window2Id": window2.windowId.uuidString,
                        "window2InitialSidebarSelection": "notifications",
                        "tabId1": tabId1.uuidString,
                        "tabId2": tabId2.uuidString,
                        "surfaceId1": surfaceId1.uuidString,
                        "surfaceId2": surfaceId2.uuidString,
                        "notifId1": notif1?.id.uuidString ?? "",
                        "notifId2": notif2?.id.uuidString ?? "",
                        "expectedLatestWindowId": window1.windowId.uuidString,
                        "expectedLatestTabId": tabId1.uuidString,
                    ], at: path)
                    self.prepareMultiWindowNotificationSourceTerminalIfNeeded(
                        at: path,
                        windowId: window1.windowId,
                        tabManager: window1.tabManager,
                        tabId: tabId1,
                        surfaceId: surfaceId1
                    )
                    self.publishMultiWindowNotificationSocketStateIfNeeded(at: path)
                }
                }
            }
        }
    }

    private func prepareMultiWindowNotificationSourceTerminalIfNeeded(
        at path: String,
        windowId: UUID,
        tabManager: TabManager,
        tabId: UUID,
        surfaceId: UUID
    ) {
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_NOTIFY_SOURCE_TERMINAL_READY"] == "1" else { return }

        writeMultiWindowNotificationTestData([
            "sourceTerminalReady": "pending",
            "sourceTerminalFocusFailure": "",
        ], at: path)

        let deadline = Date().addingTimeInterval(8.0)

        func publish(ready: Bool, failure: String = "") {
            writeMultiWindowNotificationTestData([
                "sourceTerminalReady": ready ? "1" : "0",
                "sourceTerminalFocusFailure": failure,
            ], at: path)
        }

        var resolved = false
        var observers: [NSObjectProtocol] = []
        var selectedTabCancellable: AnyCancellable?
        var panelsCancellable: AnyCancellable?

        func cleanup() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            selectedTabCancellable?.cancel()
            panelsCancellable?.cancel()
        }

        func attemptFocus() {
            guard !resolved else { return }
            guard let workspace = tabManager.tabs.first(where: { $0.id == tabId }) else {
                resolved = true
                cleanup()
                publish(ready: false, failure: "workspace_missing")
                return
            }
            panelsCancellable?.cancel()
            panelsCancellable = workspace.$panels
                .map { _ in () }
                .sink { _ in attemptFocus() }
            guard let terminalPanel = workspace.terminalPanel(for: surfaceId) else {
                resolved = true
                cleanup()
                publish(ready: false, failure: "terminal_missing")
                return
            }

            let isWindowFrontmost = {
                guard let window = self.mainWindow(for: windowId) else { return false }
                return NSApp.keyWindow === window || NSApp.mainWindow === window
            }()
            if isWindowFrontmost && terminalPanel.hostedView.isSurfaceViewFirstResponder() {
                resolved = true
                cleanup()
                publish(ready: true)
                return
            }

            guard Date() < deadline else {
                resolved = true
                cleanup()
                publish(
                    ready: false,
                    failure: isWindowFrontmost ? "terminal_not_first_responder" : "window_not_frontmost"
                )
                return
            }

            _ = self.focusMainWindow(windowId: windowId)
            if let tab = tabManager.tabs.first(where: { $0.id == tabId }) {
                tabManager.selectTab(tab)
                tabManager.focusSurface(tabId: tabId, surfaceId: surfaceId)
            }
        }

        observers.append(NotificationCenter.default.addObserver(
            forName: .mainWindowContextsDidChange,
            object: self,
            queue: .main
        ) { _ in
            attemptFocus()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidBecomeFirstResponderSurface,
            object: nil,
            queue: .main
        ) { note in
            guard let candidateTabId = note.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                  let candidateSurfaceId = note.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID,
                  candidateTabId == tabId,
                  candidateSurfaceId == surfaceId else { return }
            attemptFocus()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusSurface,
            object: nil,
            queue: .main
        ) { note in
            guard let candidateTabId = note.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                  let candidateSurfaceId = note.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID,
                  candidateTabId == tabId,
                  candidateSurfaceId == surfaceId else { return }
            attemptFocus()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: nil,
            queue: .main
        ) { note in
            guard let workspaceId = note.userInfo?["workspaceId"] as? UUID,
                  let readySurfaceId = note.userInfo?["surfaceId"] as? UUID,
                  workspaceId == tabId,
                  readySurfaceId == surfaceId else { return }
            attemptFocus()
        })
        selectedTabCancellable = tabManager.$selectedTabId
            .map { _ in () }
            .sink { _ in attemptFocus() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
            if !resolved {
                attemptFocus()
            }
        }
        attemptFocus()
    }

    private func publishMultiWindowNotificationSocketStateIfNeeded(at path: String) {
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_SOCKET_SANITY"] == "1" else { return }

        guard let config = socketListenerConfigurationIfEnabled() else {
            writeMultiWindowNotificationTestData([
                "socketExpectedPath": env["CMUX_SOCKET_PATH"] ?? "",
                "socketMode": "off",
                "socketReady": "0",
                "socketPingResponse": "",
                "socketIsRunning": "0",
                "socketAcceptLoopAlive": "0",
                "socketPathMatches": "0",
                "socketPathExists": "0",
                "socketFailureSignals": "socket_disabled",
            ], at: path)
            return
        }

        writeMultiWindowNotificationTestData([
            "socketExpectedPath": config.path,
            "socketMode": config.mode.rawValue,
            "socketReady": "pending",
            "socketPingResponse": "",
        ], at: path)

        let socketPath = config.path
        let socketMode = config.mode.rawValue
        var observer: NSObjectProtocol?
        var timeoutWorkItem: DispatchWorkItem?

        func publishCurrentState(isTimedOut: Bool) {
            let health = TerminalController.shared.socketListenerHealth(expectedSocketPath: socketPath)
            let dataPath = path
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let pingResponse = health.isHealthy
                    ? TerminalController.probeSocketCommand("ping", at: socketPath, timeout: 1.0)
                    : nil
                let isReady = health.isHealthy && pingResponse == "PONG"
                let failureSignals = {
                    var signals = health.failureSignals
                    if health.isHealthy && pingResponse != "PONG" {
                        signals.append("ping_timeout")
                    }
                    return signals.joined(separator: ",")
                }()

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.writeMultiWindowNotificationTestData([
                        "socketExpectedPath": socketPath,
                        "socketMode": socketMode,
                        "socketReady": isReady ? "1" : (isTimedOut ? "0" : "pending"),
                        "socketPingResponse": pingResponse ?? "",
                        "socketIsRunning": health.isRunning ? "1" : "0",
                        "socketAcceptLoopAlive": health.acceptLoopAlive ? "1" : "0",
                        "socketPathMatches": health.socketPathMatches ? "1" : "0",
                        "socketPathExists": health.socketPathExists ? "1" : "0",
                        "socketFailureSignals": failureSignals,
                    ], at: dataPath)
                    guard isReady || isTimedOut else { return }
                    timeoutWorkItem?.cancel()
                    if let observer {
                        NotificationCenter.default.removeObserver(observer)
                    }
                }
            }
        }

        observer = NotificationCenter.default.addObserver(
            forName: .socketListenerDidStart,
            object: TerminalController.shared,
            queue: .main
        ) { notification in
            let startedPath = notification.userInfo?["path"] as? String
            guard startedPath == socketPath else { return }
            publishCurrentState(isTimedOut: false)
        }

        let timeout = DispatchWorkItem {
            publishCurrentState(isTimedOut: true)
        }
        timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 20.0, execute: timeout)

        restartSocketListenerIfEnabled(source: "uiTest.multiWindowNotifications.setup")
        publishCurrentState(isTimedOut: false)
    }

    private func writeMultiWindowNotificationTestData(_ updates: [String: String], at path: String) {
        var payload = loadMultiWindowNotificationTestData(at: path)
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func loadMultiWindowNotificationTestData(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

    private func recordMultiWindowNotificationFocusIfNeeded(
        windowId: UUID,
        tabId: UUID,
        surfaceId: UUID?,
        sidebarSelection: SidebarSelection
    ) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_PATH"], !path.isEmpty else { return }
        let sidebarSelectionString: String = {
            switch sidebarSelection {
            case .tabs: return "tabs"
            case .notifications: return "notifications"
            }
        }()
        writeMultiWindowNotificationTestData([
            "focusToken": UUID().uuidString,
            "focusedWindowId": windowId.uuidString,
            "focusedTabId": tabId.uuidString,
            "focusedSurfaceId": surfaceId?.uuidString ?? "",
            "focusedSidebarSelection": sidebarSelectionString,
        ], at: path)
    }
#endif

    func attachUpdateAccessory(to window: NSWindow) {
        titlebarAccessoryController.start()
        titlebarAccessoryController.attach(to: window)
    }

    func applyWindowDecorations(to window: NSWindow) {
        windowDecorationsController.apply(to: window)
    }

    func toggleNotificationsPopover(animated: Bool = true, anchorView: NSView? = nil) {
        titlebarAccessoryController.toggleNotificationsPopover(animated: animated, anchorView: anchorView)
    }

    @discardableResult
    func dismissNotificationsPopoverIfShown() -> Bool {
        titlebarAccessoryController.dismissNotificationsPopoverIfShown()
    }

    func isNotificationsPopoverShown() -> Bool {
        titlebarAccessoryController.isNotificationsPopoverShown()
    }

    func jumpToLatestUnread() {
        guard let notificationStore else { return }
#if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
            writeJumpUnreadTestData([
                "jumpUnreadInvoked": "1",
                "jumpUnreadNotificationCount": String(notificationStore.notifications.count),
            ])
        }
#endif
        // Prefer the latest unread that we can actually open. In early startup (especially on the VM),
        // the window-context registry can lag behind model initialization, so fall back to whatever
        // tab manager currently owns the tab.
        for notification in notificationStore.notifications where !notification.isRead {
            if openNotification(tabId: notification.tabId, surfaceId: notification.surfaceId, notificationId: notification.id) {
                return
            }
        }
    }

    static func installWindowResponderSwizzlesForTesting() {
        _ = didInstallWindowKeyEquivalentSwizzle
        _ = didInstallWindowFirstResponderSwizzle
        _ = didInstallWindowSendEventSwizzle
    }

#if DEBUG
    static func setWindowFirstResponderGuardTesting(currentEvent: NSEvent?, hitView: NSView?) {
        cmuxFirstResponderGuardCurrentEventOverride = currentEvent
        cmuxFirstResponderGuardHitViewOverride = hitView
    }

    static func clearWindowFirstResponderGuardTesting() {
        cmuxFirstResponderGuardCurrentEventOverride = nil
        cmuxFirstResponderGuardHitViewOverride = nil
    }
#endif

    private func installWindowResponderSwizzles() {
        _ = Self.didInstallApplicationSendEventSwizzle
        _ = Self.didInstallWindowKeyEquivalentSwizzle
        _ = Self.didInstallWindowFirstResponderSwizzle
        _ = Self.didInstallWindowSendEventSwizzle
    }

    private func installShortcutMonitor() {
        // Local monitor only receives events when app is active (not global)
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
#if DEBUG
                let phaseTotalStart = ProcessInfo.processInfo.systemUptime
                let preludeStart = ProcessInfo.processInfo.systemUptime
                var preludeMs: Double = 0
                var shortcutMs: Double = 0
                CmuxTypingTiming.logEventDelay(path: "appMonitor", event: event)
                let shortcutMonitorTraceEnabled =
                    ProcessInfo.processInfo.environment["CMUX_SHORTCUT_MONITOR_TRACE"] == "1"
                    || UserDefaults.standard.bool(forKey: "cmuxShortcutMonitorTrace")
                if shortcutMonitorTraceEnabled {
                    let frType = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
                    dlog(
                        "monitor.keyDown: \(NSWindow.keyDescription(event)) fr=\(frType) addrBarId=\(self.browserAddressBarFocusedPanelId?.uuidString.prefix(8) ?? "nil") \(self.debugShortcutRouteSnapshot(event: event))"
                    )
                }
                if let probeKind = self.developerToolsShortcutProbeKind(event: event) {
                    self.logDeveloperToolsShortcutSnapshot(phase: "monitor.pre.\(probeKind)", event: event)
                }
                preludeMs = (ProcessInfo.processInfo.systemUptime - preludeStart) * 1000.0
                let shortcutTimingStart = CmuxTypingTiming.start()
#endif
                let shortcutStart = ProcessInfo.processInfo.systemUptime
                let handledByShortcut = self.handleCustomShortcut(event: event)
#if DEBUG
                shortcutMs = (ProcessInfo.processInfo.systemUptime - shortcutStart) * 1000.0
                CmuxTypingTiming.logDuration(
                    path: "appMonitor.handleCustomShortcut",
                    startedAt: shortcutTimingStart,
                    event: event,
                    extra: "handled=\(handledByShortcut ? 1 : 0)"
                )
                let shortcutElapsedMs = (ProcessInfo.processInfo.systemUptime - shortcutStart) * 1000.0
                self.logSlowShortcutMonitorLatencyIfNeeded(
                    event: event,
                    handledByShortcut: handledByShortcut,
                    elapsedMs: shortcutElapsedMs
                )
                let totalMs = (ProcessInfo.processInfo.systemUptime - phaseTotalStart) * 1000.0
                CmuxTypingTiming.logBreakdown(
                    path: "appMonitor.phase",
                    totalMs: totalMs,
                    event: event,
                    thresholdMs: 0.75,
                    parts: [
                        ("preludeMs", preludeMs),
                        ("shortcutMs", shortcutMs),
                    ],
                    extra: "handled=\(handledByShortcut ? 1 : 0)"
                )
#endif
                if handledByShortcut {
#if DEBUG
                    dlog("  → consumed by handleCustomShortcut")
#endif
                    return nil // Consume the event
                }
                return event // Pass through
            }
            self.handleBrowserOmnibarSelectionRepeatLifecycleEvent(event)
            if self.clearEscapeSuppressionForKeyUp(event: event, consumeIfSuppressed: true) {
                return nil
            }
            return event
        }
    }

    private func installShortcutDefaultsObserver() {
        guard shortcutDefaultsObserver == nil else { return }
        refreshConfiguredShortcutChordActions()
        shortcutDefaultsObserver = NotificationCenter.default.addObserver(
            forName: KeyboardShortcutSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshConfiguredShortcutChordActions()
            self?.clearConfiguredShortcutChordState()
            self?.scheduleSplitButtonTooltipRefreshAcrossWorkspaces()
        }
    }

    private func refreshConfiguredShortcutChordActions() {
        configuredShortcutChordActions = KeyboardShortcutSettings.Action.allCases.filter { action in
            // showHideAllWindows is dispatched via Carbon RegisterEventHotKey
            // (SystemWideHotkeyController) and never routed through AppKit's
            // local key handler. If a managed settings.json entry happened to
            // store it as a chord, arming the prefix here would swallow the
            // first stroke and leave the second one orphaned, breaking that
            // keystroke for the focused terminal/browser input.
            guard action != .showHideAllWindows else { return false }
            return KeyboardShortcutSettings.shortcut(for: action).hasChord
        }
    }

    private func clearConfiguredShortcutChordState() {
        pendingConfiguredShortcutChord = nil
        activeConfiguredShortcutChordPrefixForCurrentEvent = nil
    }

    /// Coalesce shortcut-default changes and refresh on the next runloop turn to
    /// avoid mutating Bonsplit/SwiftUI-observed state during an active update pass.
    private func scheduleSplitButtonTooltipRefreshAcrossWorkspaces() {
        guard !splitButtonTooltipRefreshScheduled else { return }
        splitButtonTooltipRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.splitButtonTooltipRefreshScheduled = false
            self.refreshSplitButtonTooltipsAcrossWorkspaces()
        }
    }

    private func refreshSplitButtonTooltipsAcrossWorkspaces() {
        var refreshedManagers: Set<ObjectIdentifier> = []
        if let manager = tabManager {
            manager.refreshSplitButtonTooltips()
            refreshedManagers.insert(ObjectIdentifier(manager))
        }
        for context in mainWindowContexts.values {
            let manager = context.tabManager
            let identifier = ObjectIdentifier(manager)
            guard refreshedManagers.insert(identifier).inserted else { continue }
            manager.refreshSplitButtonTooltips()
        }
    }

    private func installGhosttyConfigObserver() {
        guard ghosttyConfigObserver == nil else { return }
        ghosttyConfigObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyConfigDidReload,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshGhosttyGotoSplitShortcuts()
        }
    }

    private func refreshGhosttyGotoSplitShortcuts() {
        guard let config = GhosttyApp.shared.config else {
            ghosttyGotoSplitLeftShortcut = nil
            ghosttyGotoSplitRightShortcut = nil
            ghosttyGotoSplitUpShortcut = nil
            ghosttyGotoSplitDownShortcut = nil
            return
        }

        ghosttyGotoSplitLeftShortcut = storedShortcutFromGhosttyTrigger(
            ghostty_config_trigger(config, "goto_split:left", UInt("goto_split:left".utf8.count))
        )
        ghosttyGotoSplitRightShortcut = storedShortcutFromGhosttyTrigger(
            ghostty_config_trigger(config, "goto_split:right", UInt("goto_split:right".utf8.count))
        )
        ghosttyGotoSplitUpShortcut = storedShortcutFromGhosttyTrigger(
            ghostty_config_trigger(config, "goto_split:up", UInt("goto_split:up".utf8.count))
        )
        ghosttyGotoSplitDownShortcut = storedShortcutFromGhosttyTrigger(
            ghostty_config_trigger(config, "goto_split:down", UInt("goto_split:down".utf8.count))
        )
    }

    private func storedShortcutFromGhosttyTrigger(_ trigger: ghostty_input_trigger_s) -> StoredShortcut? {
        let key: String
        switch trigger.tag {
        case GHOSTTY_TRIGGER_PHYSICAL:
            switch trigger.key.physical {
            case GHOSTTY_KEY_ARROW_LEFT:
                key = "←"
            case GHOSTTY_KEY_ARROW_RIGHT:
                key = "→"
            case GHOSTTY_KEY_ARROW_UP:
                key = "↑"
            case GHOSTTY_KEY_ARROW_DOWN:
                key = "↓"
            case GHOSTTY_KEY_A: key = "a"
            case GHOSTTY_KEY_B: key = "b"
            case GHOSTTY_KEY_C: key = "c"
            case GHOSTTY_KEY_D: key = "d"
            case GHOSTTY_KEY_E: key = "e"
            case GHOSTTY_KEY_F: key = "f"
            case GHOSTTY_KEY_G: key = "g"
            case GHOSTTY_KEY_H: key = "h"
            case GHOSTTY_KEY_I: key = "i"
            case GHOSTTY_KEY_J: key = "j"
            case GHOSTTY_KEY_K: key = "k"
            case GHOSTTY_KEY_L: key = "l"
            case GHOSTTY_KEY_M: key = "m"
            case GHOSTTY_KEY_N: key = "n"
            case GHOSTTY_KEY_O: key = "o"
            case GHOSTTY_KEY_P: key = "p"
            case GHOSTTY_KEY_Q: key = "q"
            case GHOSTTY_KEY_R: key = "r"
            case GHOSTTY_KEY_S: key = "s"
            case GHOSTTY_KEY_T: key = "t"
            case GHOSTTY_KEY_U: key = "u"
            case GHOSTTY_KEY_V: key = "v"
            case GHOSTTY_KEY_W: key = "w"
            case GHOSTTY_KEY_X: key = "x"
            case GHOSTTY_KEY_Y: key = "y"
            case GHOSTTY_KEY_Z: key = "z"
            case GHOSTTY_KEY_DIGIT_0: key = "0"
            case GHOSTTY_KEY_DIGIT_1: key = "1"
            case GHOSTTY_KEY_DIGIT_2: key = "2"
            case GHOSTTY_KEY_DIGIT_3: key = "3"
            case GHOSTTY_KEY_DIGIT_4: key = "4"
            case GHOSTTY_KEY_DIGIT_5: key = "5"
            case GHOSTTY_KEY_DIGIT_6: key = "6"
            case GHOSTTY_KEY_DIGIT_7: key = "7"
            case GHOSTTY_KEY_DIGIT_8: key = "8"
            case GHOSTTY_KEY_DIGIT_9: key = "9"
            case GHOSTTY_KEY_BRACKET_LEFT: key = "["
            case GHOSTTY_KEY_BRACKET_RIGHT: key = "]"
            case GHOSTTY_KEY_MINUS: key = "-"
            case GHOSTTY_KEY_EQUAL: key = "="
            case GHOSTTY_KEY_COMMA: key = ","
            case GHOSTTY_KEY_PERIOD: key = "."
            case GHOSTTY_KEY_SLASH: key = "/"
            case GHOSTTY_KEY_SEMICOLON: key = ";"
            case GHOSTTY_KEY_QUOTE: key = "'"
            case GHOSTTY_KEY_BACKQUOTE: key = "`"
            case GHOSTTY_KEY_BACKSLASH: key = "\\"
            default:
                return nil
            }
        case GHOSTTY_TRIGGER_UNICODE:
            guard let scalar = UnicodeScalar(trigger.key.unicode) else { return nil }
            key = String(Character(scalar)).lowercased()
        case GHOSTTY_TRIGGER_CATCH_ALL:
            return nil
        default:
            return nil
        }

        let mods = trigger.mods.rawValue
        let command = (mods & GHOSTTY_MODS_SUPER.rawValue) != 0
        let shift = (mods & GHOSTTY_MODS_SHIFT.rawValue) != 0
        let option = (mods & GHOSTTY_MODS_ALT.rawValue) != 0
        let control = (mods & GHOSTTY_MODS_CTRL.rawValue) != 0

        // Ignore bogus empty triggers.
        if key.isEmpty || (!command && !shift && !option && !control) {
            return nil
        }

        return StoredShortcut(key: key, command: command, shift: shift, option: option, control: control)
    }

    private func handleQuitShortcutWarning() -> Bool {
        // Tagged DEV builds are ephemeral, skip quit confirmation entirely.
        if SocketControlSettings.isTaggedDevBuild() {
            NSApp.terminate(nil)
            return true
        }

        if !QuitWarningSettings.isEnabled() {
            NSApp.terminate(nil)
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "dialog.quitCmux.title", defaultValue: "Quit cmux?")
        alert.informativeText = String(localized: "dialog.quitCmux.message", defaultValue: "This will close all windows and workspaces.")
        alert.addButton(withTitle: String(localized: "dialog.quitCmux.quit", defaultValue: "Quit"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "dialog.dontWarnCmdQ", defaultValue: "Don't warn again for Cmd+Q")

        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            QuitWarningSettings.setEnabled(false)
        }

        if response == .alertFirstButtonReturn {
            // Mark as confirmed so applicationShouldTerminate does not show a
            // second alert when NSApp.terminate re-enters the delegate callback.
            isQuitWarningConfirmed = true
            NSApp.terminate(nil)
        }
        return true
    }

    func promptRenameSelectedWorkspace() -> Bool {
        guard let tabManager,
              let tabId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
            NSSound.beep()
            return false
        }

        let alert = NSAlert()
        alert.messageText = String(localized: "dialog.renameWorkspace.title", defaultValue: "Rename Workspace")
        alert.informativeText = String(localized: "dialog.renameWorkspace.message", defaultValue: "Enter a custom name for this workspace.")
        let input = NSTextField(string: tab.customTitle ?? tab.title)
        input.placeholderString = String(localized: "dialog.renameWorkspace.placeholder", defaultValue: "Workspace name")
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "common.rename", defaultValue: "Rename"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return true }
        tabManager.setCustomTitle(tabId: tab.id, title: input.stringValue)
        return true
    }

    private func handleCustomShortcut(event: NSEvent) -> Bool {
        // `charactersIgnoringModifiers` can be nil for some synthetic NSEvents and certain special keys.
        // Treat nil as "" and rely on keyCode/layout-aware fallback logic where needed.
        // When a non-Latin input source is active (Korean, Chinese, Japanese, etc.),
        // charactersIgnoringModifiers returns non-ASCII characters that never match
        // Latin shortcut keys. Normalize via KeyboardLayout so downstream comparisons
        // (Cmd+1-9, Ctrl+1-9, omnibar N/P, command palette, etc.) work correctly.
        let chars = KeyboardLayout.normalizedCharacters(for: event)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasControl = flags.contains(.control)
        let hasCommand = flags.contains(.command)
        let hasOption = flags.contains(.option)
        let isControlOnly = hasControl && !hasCommand && !hasOption
        let controlDChar = chars == "d" || event.characters == "\u{04}"
        let isControlD = isControlOnly && (controlDChar || event.keyCode == 2)
        let configuredShortcutEventWindowNumber = configuredShortcutChordWindowNumber(for: event)
        if let pendingConfiguredShortcutChord,
           pendingConfiguredShortcutChord.windowNumber == configuredShortcutEventWindowNumber {
            activeConfiguredShortcutChordPrefixForCurrentEvent = pendingConfiguredShortcutChord.firstStroke
        } else {
            activeConfiguredShortcutChordPrefixForCurrentEvent = nil
        }
        pendingConfiguredShortcutChord = nil
        defer { activeConfiguredShortcutChordPrefixForCurrentEvent = nil }
#if DEBUG
        if isControlD {
            writeChildExitKeyboardProbe(
                [
                    "probeAppShortcutCharsHex": childExitKeyboardProbeHex(event.characters),
                    "probeAppShortcutCharsIgnoringHex": childExitKeyboardProbeHex(event.charactersIgnoringModifiers),
                    "probeAppShortcutKeyCode": String(event.keyCode),
                    "probeAppShortcutModsRaw": String(event.modifierFlags.rawValue),
                ],
                increments: ["probeAppShortcutCtrlDSeenCount": 1]
            )
        }
#endif

        // Don't steal shortcuts from close-confirmation alerts. Keep standard alert key
        // equivalents working and avoid surprising actions while the confirmation is up.
        let closeConfirmationTitles = [
            String(localized: "dialog.closeWorkspace.title", defaultValue: "Close workspace?"),
            String(localized: "dialog.closeWorkspaces.title", defaultValue: "Close workspaces?"),
            String(localized: "dialog.closeTab.title", defaultValue: "Close tab?"),
            String(localized: "dialog.closeOtherTabs.title", defaultValue: "Close other tabs?"),
            String(localized: "dialog.closeWindow.title", defaultValue: "Close window?"),
        ]
        let closeConfirmationPanel = NSApp.windows
            .compactMap { $0 as? NSPanel }
            .first { panel in
                guard panel.isVisible, let root = panel.contentView else { return false }
                return closeConfirmationTitles.contains { title in
                    findStaticText(in: root, equals: title)
                }
            }
        if let closeConfirmationPanel {
            // Special-case: Cmd+D should confirm destructive close on alerts.
            // XCUITest key events often hit the app-level local monitor first, so forward the key
            // equivalent to the alert panel explicitly.
            if matchShortcut(
                event: event,
                shortcut: StoredShortcut(key: "d", command: true, shift: false, option: false, control: false)
            ),
               let root = closeConfirmationPanel.contentView,
               let closeButton = findButton(
                   in: root,
                   titled: String(localized: "common.close", defaultValue: "Close")
               ) {
                closeButton.performClick(nil)
                return true
            }
            return false
        }

        if NSApp.modalWindow != nil || NSApp.keyWindow?.attachedSheet != nil {
            return false
        }

        let normalizedFlags = flags.subtracting([.numericPad, .function, .capsLock])
        let commandPaletteTargetWindow = commandPaletteWindowForShortcutEvent(event)
        let commandPaletteShortcutWindow = shouldHandleCommandPaletteShortcutEvent(
            event,
            paletteWindow: commandPaletteTargetWindow
        ) ? commandPaletteTargetWindow : nil
        let commandPaletteVisibleInTargetWindow = commandPaletteShortcutWindow.map {
            isCommandPaletteVisible(for: $0)
        } ?? false
        let commandPalettePendingOpenInTargetWindow = commandPaletteTargetWindow.map {
            isCommandPalettePendingOpen(for: $0)
        } ?? false
        let commandPaletteOverlayVisibleInTargetWindow = commandPaletteTargetWindow.map {
            isCommandPaletteOverlayPresented(in: $0)
        } ?? false
        let commandPaletteResponderActiveInTargetWindow = commandPaletteTargetWindow.map {
            isCommandPaletteResponderActive(in: $0)
        } ?? false
        let commandPaletteInteractiveInTargetWindow =
            commandPaletteVisibleInTargetWindow
            || commandPaletteOverlayVisibleInTargetWindow
            || commandPaletteResponderActiveInTargetWindow
        let commandPaletteEffectiveInTargetWindow =
            commandPaletteInteractiveInTargetWindow
            || commandPalettePendingOpenInTargetWindow

#if DEBUG
        if event.keyCode == 36 || event.keyCode == 76 {
            dlog(
                "shortcut.return.raw " +
                "interactive=\(commandPaletteInteractiveInTargetWindow ? 1 : 0) " +
                "effective=\(commandPaletteEffectiveInTargetWindow ? 1 : 0) " +
                "target={\(debugWindowToken(commandPaletteTargetWindow))} " +
                "shortcutWindow={\(debugWindowToken(commandPaletteShortcutWindow))} " +
                "responderTarget=\(commandPaletteResponderActiveInTargetWindow ? 1 : 0) " +
                "overlayTarget=\(commandPaletteOverlayVisibleInTargetWindow ? 1 : 0) " +
                "pendingTarget=\(commandPalettePendingOpenInTargetWindow ? 1 : 0) " +
                "\(debugShortcutRouteSnapshot(event: event))"
            )
        }
#endif

        if normalizedFlags.isEmpty, event.keyCode == 53 {
            let activePaletteWindow = activeCommandPaletteWindow()
            let escapePaletteWindow: NSWindow? = {
                if let targetWindow = commandPaletteTargetWindow {
                    guard commandPaletteEffectiveInTargetWindow else {
                        return nil
                    }
                    return targetWindow
                }
                return activePaletteWindow
            }()
#if DEBUG
            dlog(
                "shortcut.escape route target={\(debugWindowToken(commandPaletteTargetWindow))} " +
                "active={\(debugWindowToken(activePaletteWindow))} " +
                "visibleTarget=\(commandPaletteVisibleInTargetWindow ? 1 : 0) " +
                "pendingTarget=\(commandPalettePendingOpenInTargetWindow ? 1 : 0) " +
                "overlayTarget=\(commandPaletteOverlayVisibleInTargetWindow ? 1 : 0) " +
                "responderTarget=\(commandPaletteResponderActiveInTargetWindow ? 1 : 0) " +
                "effectiveTarget=\(commandPaletteEffectiveInTargetWindow ? 1 : 0) " +
                "\(debugShortcutRouteSnapshot(event: event))"
            )
            if commandPaletteTargetWindow != nil,
               !commandPaletteVisibleInTargetWindow,
               !commandPalettePendingOpenInTargetWindow,
               (commandPaletteOverlayVisibleInTargetWindow || commandPaletteResponderActiveInTargetWindow) {
                dlog(
                    "shortcut.escape stateMismatch target={\(debugWindowToken(commandPaletteTargetWindow))} " +
                    "overlayTarget=\(commandPaletteOverlayVisibleInTargetWindow ? 1 : 0) " +
                    "responderTarget=\(commandPaletteResponderActiveInTargetWindow ? 1 : 0)"
                )
            }
#endif
            if let paletteWindow = escapePaletteWindow,
               isCommandPaletteEffectivelyVisible(in: paletteWindow) {
                if commandPaletteMarkedTextInput(in: paletteWindow) != nil {
#if DEBUG
                    dlog(
                        "shortcut.escape imeMarkedTextBypass consumed=0 target={\(debugWindowToken(paletteWindow))}"
                    )
#endif
                    return false
                }
                clearCommandPalettePendingOpen(for: paletteWindow)
                beginCommandPaletteEscapeSuppression(for: paletteWindow)
                NotificationCenter.default.post(name: .commandPaletteToggleRequested, object: paletteWindow)
#if DEBUG
                dlog("shortcut.escape paletteDismiss consumed=1 target={\(debugWindowToken(paletteWindow))}")
#endif
                return true
            }
            let suppressionWindow = commandPaletteTargetWindow
                ?? event.window
                ?? NSApp.keyWindow
                ?? NSApp.mainWindow
            if shouldConsumeSuppressedEscape(event: event, window: suppressionWindow) {
#if DEBUG
                dlog(
                    "shortcut.escape suppressionConsume consumed=1 target={\(debugWindowToken(suppressionWindow))} " +
                    "repeat=\(event.isARepeat ? 1 : 0)"
                )
#endif
                return true
            }
            if let requestAge = recentCommandPaletteRequestAge(for: suppressionWindow) {
                beginCommandPaletteEscapeSuppression(for: suppressionWindow)
#if DEBUG
                dlog(
                    "shortcut.escape requestGraceConsume consumed=1 target={\(debugWindowToken(suppressionWindow))} " +
                    "ageMs=\(Int(requestAge * 1000)) repeat=\(event.isARepeat ? 1 : 0)"
                )
#endif
                return true
            }
#if DEBUG
            dlog(
                "shortcut.escape paletteDismiss consumed=0 target={\(debugWindowToken(commandPaletteTargetWindow))} " +
                "active={\(debugWindowToken(activePaletteWindow))}"
            )
#endif
        }

        let paletteUsesInlineTextHandling = commandPaletteShortcutWindow.map {
            isCommandPaletteMultilineTextResponderActive(in: $0)
        } ?? false

        let paletteSelectionDelta = commandPaletteSelectionDeltaForKeyboardNavigation(
            flags: event.modifierFlags,
            chars: chars,
            keyCode: event.keyCode
        )

        if shouldRouteCommandPaletteSelectionNavigation(
            delta: paletteSelectionDelta,
            isInteractive: commandPaletteInteractiveInTargetWindow,
            usesInlineTextHandling: paletteUsesInlineTextHandling
        ),
           let delta = paletteSelectionDelta,
           let paletteWindow = commandPaletteShortcutWindow {
            NotificationCenter.default.post(
                name: .commandPaletteMoveSelection,
                object: paletteWindow,
                userInfo: ["delta": delta]
            )
            return true
        }

        if commandPaletteInteractiveInTargetWindow,
           let paletteWindow = commandPaletteShortcutWindow {
            let paletteFieldEditorHasMarkedText = commandPaletteFieldEditorHasMarkedText(in: paletteWindow)
            let paletteSnapshot = mainWindowId(for: paletteWindow).map(commandPaletteSnapshot(windowId:)) ?? .empty
            let paletteUsesInlineReturnHandling = paletteUsesInlineTextHandling
            if normalizedFlags.isEmpty, event.keyCode == 53 {
                if paletteFieldEditorHasMarkedText {
                    return false
                }
                NotificationCenter.default.post(name: .commandPaletteDismissRequested, object: paletteWindow)
                return true
            }

            let shouldSubmitPalette = shouldSubmitCommandPaletteWithReturn(
                keyCode: event.keyCode,
                flags: event.modifierFlags,
                mode: paletteSnapshot.mode
            )
#if DEBUG
            if event.keyCode == 36 || event.keyCode == 76 {
                dlog(
                    "shortcut.palette.return target={\(debugWindowToken(paletteWindow))} " +
                    "mode=\(paletteSnapshot.mode) " +
                    "inline=\(paletteUsesInlineReturnHandling ? 1 : 0) " +
                    "submit=\(shouldSubmitPalette ? 1 : 0) " +
                    "marked=\(paletteFieldEditorHasMarkedText ? 1 : 0) " +
                    "\(debugShortcutRouteSnapshot(event: event))"
                )
            }
#endif
            if paletteUsesInlineReturnHandling,
               event.keyCode == 36 || event.keyCode == 76 {
                return false
            }
            if shouldSubmitPalette {
                if paletteFieldEditorHasMarkedText {
                    return false
                }
                NotificationCenter.default.post(name: .commandPaletteSubmitRequested, object: paletteWindow)
                return true
            }
        }

        // Guard against stale browserAddressBarFocusedPanelId after focus transitions
        // (e.g., split that doesn't properly blur the address bar). If the first responder
        // is a terminal surface, the address bar can't be focused.
        if browserAddressBarFocusedPanelId != nil,
           cmuxOwningGhosttyView(for: NSApp.keyWindow?.firstResponder) != nil {
#if DEBUG
            let stalePanelToken = browserAddressBarFocusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
            let firstResponderType = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            dlog(
                "browser.focus.addressBar.staleClear panel=\(stalePanelToken) " +
                "reason=terminal_first_responder fr=\(firstResponderType)"
            )
#endif
            browserAddressBarFocusedPanelId = nil
            stopBrowserOmnibarSelectionRepeat()
        }

        // Keep Cmd+P/Cmd+N inside the focused browser omnibar for Chrome-like
        // suggestion navigation, and avoid opening command palette switcher.
        // Scope the omnibar check to the shortcut's routed window context so a
        // focused omnibar in another window does not suppress Cmd+P here.
        let hasFocusedAddressBarInShortcutContext = focusedBrowserAddressBarPanelIdForShortcutEvent(event) != nil

        if commandPaletteEffectiveInTargetWindow {
            if matchConfiguredShortcut(event: event, action: .commandPalette) {
                let targetWindow = commandPaletteTargetWindow ?? event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
                requestCommandPaletteCommands(preferredWindow: targetWindow, source: "shortcut.commandPalette")
                return true
            }

            if !hasFocusedAddressBarInShortcutContext,
               matchConfiguredShortcut(event: event, action: .goToWorkspace) {
                let targetWindow = commandPaletteTargetWindow ?? event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
                requestCommandPaletteSwitcher(preferredWindow: targetWindow, source: "shortcut.goToWorkspace")
                return true
            }

            if activeConfiguredShortcutChordPrefixForCurrentEvent == nil,
               armConfiguredShortcutChordIfNeeded(event: event, actions: [.commandPalette]) {
                return true
            }

            if activeConfiguredShortcutChordPrefixForCurrentEvent == nil,
               !hasFocusedAddressBarInShortcutContext,
               armConfiguredShortcutChordIfNeeded(event: event, actions: [.goToWorkspace]) {
                return true
            }
        }

        if shouldConsumeShortcutWhileCommandPaletteVisible(
            isCommandPaletteVisible: commandPaletteEffectiveInTargetWindow,
            normalizedFlags: normalizedFlags,
            chars: chars,
            keyCode: event.keyCode
        ) {
            return true
        }

        // When the terminal has active IME composition (e.g. Korean, Japanese, Chinese
        // input), don't intercept non-Cmd key events — let them flow through to the
        // input method. Cmd-based shortcuts (Cmd+T, Cmd+Shift+L, etc.) should still
        // work during composition since Cmd is never part of IME input sequences.
        if !normalizedFlags.contains(.command),
           let ghosttyView = cmuxOwningGhosttyView(for: NSApp.keyWindow?.firstResponder),
           ghosttyView.hasMarkedText() {
            return false
        }

        // When the notifications popover is open, Escape should dismiss it immediately.
        if flags.isEmpty, event.keyCode == 53, titlebarAccessoryController.dismissNotificationsPopoverIfShown() {
            return true
        }

        // When the notifications popover is showing an empty state, consume plain typing
        // so key presses do not leak through into the focused terminal.
        if flags.isDisjoint(with: [.command, .control, .option]),
           titlebarAccessoryController.isNotificationsPopoverShown(),
           (notificationStore?.notifications.isEmpty ?? false) {
            return true
        }

        let hasEventWindowContext = shortcutEventHasAddressableWindow(event)
        let didSynchronizeShortcutContext = synchronizeShortcutRoutingContext(event: event)
        if hasEventWindowContext && !didSynchronizeShortcutContext {
#if DEBUG
            dlog("handleCustomShortcut: unresolved event window context; bypassing app shortcut handling")
#endif
            return false
        }

        // Keep keyboard routing deterministic after split close/reparent transitions:
        // before processing shortcuts, converge first responder with the focused terminal panel.
        if isControlD {
#if DEBUG
            let selected = tabManager?.selectedTabId?.uuidString.prefix(5) ?? "nil"
            let focused = tabManager?.selectedWorkspace?.focusedPanelId?.uuidString.prefix(5) ?? "nil"
            let frType = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            dlog("shortcut.ctrlD stage=preReconcile selected=\(selected) focused=\(focused) fr=\(frType)")
#endif
            tabManager?.reconcileFocusedPanelFromFirstResponderForKeyboard()
            #if DEBUG
            let frAfterType = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            dlog("shortcut.ctrlD stage=postReconcile fr=\(frAfterType)")
            writeChildExitKeyboardProbe([:], increments: ["probeAppShortcutCtrlDPassedCount": 1])
            #endif
            // Ctrl+D belongs to the focused terminal surface; never treat it as an app shortcut.
            return false
        }

        // Chrome-like omnibar navigation while holding Cmd+N / Ctrl+N / Cmd+P / Ctrl+P.
        if let delta = commandOmnibarSelectionDelta(
            hasFocusedAddressBar: hasFocusedAddressBarInShortcutContext,
            flags: flags,
            chars: chars
        ) {
            dispatchBrowserOmnibarSelectionMove(delta: delta)
            startBrowserOmnibarSelectionRepeatIfNeeded(keyCode: event.keyCode, delta: delta)
            return true
        }

        if let delta = browserOmnibarSelectionDeltaForArrowNavigation(
            hasFocusedAddressBar: hasFocusedAddressBarInShortcutContext,
            flags: event.modifierFlags,
            keyCode: event.keyCode
        ) {
            dispatchBrowserOmnibarSelectionMove(delta: delta)
            return true
        }

        // Fast path for normal typing and terminal navigation keys (for example Up-arrow
        // history): after command-palette/notification handling and browser omnibar
        // arrow navigation above, plain key events have no app-level shortcut behavior.
        if normalizedFlags.isEmpty && activeConfiguredShortcutChordPrefixForCurrentEvent == nil {
            return false
        }

        // Let omnibar-local Emacs navigation (Cmd/Ctrl+N/P) win while the browser
        // address bar is focused. Without this, app-level Cmd+N can steal focus.
        if hasFocusedAddressBarInShortcutContext,
           shouldBypassAppShortcutForFocusedBrowserAddressBar(flags: flags, chars: chars) {
            return false
        }

        if activeConfiguredShortcutChordPrefixForCurrentEvent == nil,
           armConfiguredShortcutChordIfNeeded(event: event) {
            return true
        }

        if matchConfiguredShortcut(event: event, action: .commandPalette) {
            let targetWindow = commandPaletteTargetWindow ?? event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
            requestCommandPaletteCommands(preferredWindow: targetWindow, source: "shortcut.commandPalette")
            return true
        }

        if !hasFocusedAddressBarInShortcutContext,
           matchConfiguredShortcut(event: event, action: .goToWorkspace) {
            let targetWindow = commandPaletteTargetWindow ?? event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
            requestCommandPaletteSwitcher(preferredWindow: targetWindow, source: "shortcut.goToWorkspace")
            return true
        }

        if matchConfiguredShortcut(event: event, action: .quit) {
            return handleQuitShortcutWarning()
        }
        if matchConfiguredShortcut(event: event, action: .openSettings) {
            openPreferencesWindow(debugSource: "shortcut.openSettings")
            return true
        }
        if matchConfiguredShortcut(event: event, action: .reloadConfiguration) {
            GhosttyApp.shared.reloadConfiguration(source: "shortcut.reloadConfiguration")
            return true
        }

        if matchConfiguredShortcut(event: event, action: .toggleFullScreen) {
            guard let targetWindow = mainWindowForShortcutEvent(event) else {
                return false
            }
            targetWindow.toggleFullScreen(nil)
            return true
        }

        // Primary UI shortcuts
        if matchConfiguredShortcut(event: event, action: .toggleSidebar) {
            _ = toggleSidebarInActiveMainWindow()
            return true
        }

        if matchConfiguredShortcut(event: event, action: .newTab) {
#if DEBUG
            dlog("shortcut.action name=newWorkspace \(debugShortcutRouteSnapshot(event: event))")
#endif
            // Cmd+N semantics:
            // - If there are no main windows, create a new window.
            // - Otherwise, create a new workspace in the active window.
            if mainWindowContexts.isEmpty {
                #if DEBUG
                logWorkspaceCreationRouting(
                    phase: "fallback_new_window",
                    source: "shortcut.cmdN",
                    reason: "no_main_windows",
                    event: event,
                    chosenContext: nil
                )
                #endif
                openNewMainWindow(nil)
            } else if addWorkspaceInPreferredMainWindow(event: event, debugSource: "shortcut.cmdN") == nil {
                #if DEBUG
                logWorkspaceCreationRouting(
                    phase: "fallback_new_window",
                    source: "shortcut.cmdN",
                    reason: "workspace_creation_returned_nil",
                    event: event,
                    chosenContext: nil
                )
                #endif
                openNewMainWindow(nil)
            }
            return true
        }

        // New Window: Cmd+Shift+N
        // Handled here instead of relying on SwiftUI's CommandGroup menu item because
        // after a browser panel has been shown, SwiftUI's menu dispatch can silently
        // consume the key equivalent without firing the action closure.
        if matchConfiguredShortcut(event: event, action: .newWindow) {
            openNewMainWindow(nil)
            return true
        }

        // Open Folder: Cmd+O
        // Handled here to prevent AppKit's default NSDocumentController from opening
        // the Documents folder when SwiftUI menu dispatch fails due to focus bugs.
        if matchConfiguredShortcut(event: event, action: .openFolder) {
            showOpenFolderPanel()
            return true
        }

        // Check Show Notifications shortcut
        if matchConfiguredShortcut(event: event, action: .showNotifications) {
            toggleNotificationsPopover(animated: false, anchorView: fullscreenControlsViewModel?.notificationsAnchorView)
            return true
        }

        if matchConfiguredShortcut(event: event, action: .sendFeedback) {
            guard let targetContext = preferredMainWindowContextForShortcuts(event: event),
                  let targetWindow = targetContext.window ?? windowForMainWindowId(targetContext.windowId) else {
                return false
            }
            setActiveMainWindow(targetWindow)
            bringToFront(targetWindow)
            NotificationCenter.default.post(name: .feedbackComposerRequested, object: targetWindow)
            return true
        }

        // Check Jump to Unread shortcut
        if matchConfiguredShortcut(event: event, action: .jumpToUnread) {
#if DEBUG
            if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
                writeJumpUnreadTestData(["jumpUnreadShortcutHandled": "1"])
            }
#endif
            jumpToLatestUnread()
            return true
        }

        // Flash the currently focused panel so the user can visually confirm focus.
        if matchConfiguredShortcut(event: event, action: .triggerFlash) {
            tabManager?.triggerFocusFlash()
            return true
        }

        // Surface navigation: Cmd+Shift+] / Cmd+Shift+[
        if matchConfiguredShortcut(event: event, action: .nextSurface) {
            tabManager?.selectNextSurface()
            return true
        }
        if matchConfiguredShortcut(event: event, action: .prevSurface) {
            tabManager?.selectPreviousSurface()
            return true
        }

        if matchConfiguredShortcut(event: event, action: .toggleTerminalCopyMode) {
            let handled = tabManager?.toggleFocusedTerminalCopyMode() ?? false
#if DEBUG
            dlog(
                "shortcut.action name=toggleTerminalCopyMode handled=\(handled ? 1 : 0) " +
                "\(debugShortcutRouteSnapshot(event: event))"
            )
#endif
            // Only consume when a focused terminal actually handled the toggle.
            // Otherwise allow the event to continue through the responder chain.
            return handled
        }

        // Workspace navigation: Cmd+Ctrl+] / Cmd+Ctrl+[
        if matchConfiguredShortcut(event: event, action: .nextSidebarTab) {
#if DEBUG
            let selected = tabManager?.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
            dlog(
                "ws.shortcut dir=next repeat=\(event.isARepeat ? 1 : 0) keyCode=\(event.keyCode) selected=\(selected)"
            )
#endif
            tabManager?.selectNextTab()
            return true
        }

        if matchConfiguredShortcut(event: event, action: .prevSidebarTab) {
#if DEBUG
            let selected = tabManager?.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
            dlog(
                "ws.shortcut dir=prev repeat=\(event.isARepeat ? 1 : 0) keyCode=\(event.keyCode) selected=\(selected)"
            )
#endif
            tabManager?.selectPreviousTab()
            return true
        }

        if matchConfiguredShortcut(event: event, action: .renameWorkspace) {
            return requestRenameWorkspaceViaCommandPalette(
                preferredWindow: commandPaletteTargetWindow ?? event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
            )
        }

        if matchConfiguredShortcut(event: event, action: .editWorkspaceDescription) {
#if DEBUG
            dlog(
                "shortcut.editWorkspaceDescription matched target={\(debugWindowToken(commandPaletteTargetWindow ?? event.window ?? NSApp.keyWindow ?? NSApp.mainWindow))} " +
                "\(debugShortcutRouteSnapshot(event: event))"
            )
#endif
            return requestEditWorkspaceDescriptionViaCommandPalette(
                preferredWindow: commandPaletteTargetWindow ?? event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
            )
        }

        if matchConfiguredShortcut(event: event, action: .closeOtherTabsInPane) {
            if let targetWindow = event.window ?? NSApp.keyWindow ?? NSApp.mainWindow,
               targetWindow.identifier?.rawValue == "cmux.settings" {
                targetWindow.performClose(nil)
            } else {
                let targetWindow = event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
                if let terminalContext = focusedTerminalShortcutContext(preferredWindow: targetWindow) {
                    terminalContext.tabManager.closeOtherTabsInFocusedPaneWithConfirmation()
                } else {
                    tabManager?.closeOtherTabsInFocusedPaneWithConfirmation()
                }
            }
            return true
        }

        // Cmd+W must close the focused panel even if first-responder momentarily lags on a
        // browser NSTextView during split focus transitions.
        if matchConfiguredShortcut(event: event, action: .closeTab) {
            let targetWindow = resolvedShortcutEventWindow(event) ?? NSApp.keyWindow ?? NSApp.mainWindow
            let routedManager = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager
            // Browser popup windows primarily intercept Cmd+W in BrowserPopupPanel.
            // This AppDelegate path is a fallback for cases where AppKit routes the
            // event through the global shortcut handler first.
            if let targetWindow = [targetWindow, NSApp.keyWindow]
                .compactMap({ $0 })
                .first(where: { $0.identifier?.rawValue == "cmux.browser-popup" }) {
#if DEBUG
                dlog("shortcut.cmdW route=browserPopup")
#endif
                targetWindow.performClose(nil)
                return true
            } else if let targetWindow,
               cmuxWindowShouldOwnCloseShortcut(targetWindow) {
                targetWindow.performClose(nil)
            } else {
                if let routedManager {
#if DEBUG
                    let selectedWorkspace = routedManager.selectedWorkspace
                    dlog(
                        "shortcut.cmdW route=workspaceModel workspace=\(selectedWorkspace?.id.uuidString.prefix(5) ?? "nil") " +
                        "panel=\(selectedWorkspace?.focusedPanelId?.uuidString.prefix(5) ?? "nil") " +
                        "selected=\(routedManager.selectedTabId?.uuidString.prefix(5) ?? "nil")"
                    )
#endif
                    routedManager.closeCurrentPanelWithConfirmation()
                } else {
#if DEBUG
                    dlog("shortcut.cmdW route=noManager")
#endif
                    return false
                }
            }
            return true
        }

        if matchConfiguredShortcut(event: event, action: .closeWorkspace) {
            tabManager?.closeCurrentWorkspaceWithConfirmation()
            return true
        }

        if matchConfiguredShortcut(event: event, action: .closeWindow) {
            guard let targetWindow = event.window ?? NSApp.keyWindow ?? NSApp.mainWindow else {
                NSSound.beep()
                return true
            }
            closeWindowWithConfirmation(targetWindow)
            return true
        }

        if matchConfiguredShortcut(event: event, action: .renameTab) {
            // Keep Cmd+R browser reload behavior when a browser panel is focused.
            if tabManager?.focusedBrowserPanel != nil {
                return false
            }
            let targetWindow = commandPaletteTargetWindow ?? event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
            requestCommandPaletteRenameTab(preferredWindow: targetWindow, source: "shortcut.renameTab")
            return true
        }

        // Numeric shortcuts for specific workspaces (9 = last workspace)
        // Always consume the event when the digit matches to prevent Ghostty's
        // goto_tab fallback from creating a new window when the index is out of bounds.
        if let digit = numberedConfiguredShortcutDigit(event: event, action: .selectWorkspaceByNumber) {
            if let manager = tabManager,
               let targetIndex = WorkspaceShortcutMapper.workspaceIndex(forDigit: digit, workspaceCount: manager.tabs.count) {
#if DEBUG
                dlog(
                    "shortcut.action name=workspaceDigit digit=\(digit) targetIndex=\(targetIndex) manager=\(debugManagerToken(manager)) \(debugShortcutRouteSnapshot(event: event))"
                )
#endif
                manager.selectTab(at: targetIndex)
            }
            return true
        }

        // Numeric shortcuts for surfaces within the focused pane (9 = last)
        if let digit = numberedConfiguredShortcutDigit(event: event, action: .selectSurfaceByNumber) {
            if digit == 9 {
                tabManager?.selectLastSurface()
            } else {
                tabManager?.selectSurface(at: digit - 1)
            }
            return true
        }

        // Pane focus navigation (defaults to Cmd+Option+Arrow, but can be customized to letter/number keys).
        if matchConfiguredDirectionalShortcut(
            event: event,
            action: .focusLeft,
            arrowGlyph: "←",
            arrowKeyCode: 123
        ) || (ghosttyGotoSplitLeftShortcut.map { matchDirectionalShortcut(event: event, shortcut: $0, arrowGlyph: "←", arrowKeyCode: 123) } ?? false) {
            tabManager?.movePaneFocus(direction: .left)
#if DEBUG
            recordGotoSplitMoveIfNeeded(direction: .left)
#endif
            return true
        }
        if matchConfiguredDirectionalShortcut(
            event: event,
            action: .focusRight,
            arrowGlyph: "→",
            arrowKeyCode: 124
        ) || (ghosttyGotoSplitRightShortcut.map { matchDirectionalShortcut(event: event, shortcut: $0, arrowGlyph: "→", arrowKeyCode: 124) } ?? false) {
            tabManager?.movePaneFocus(direction: .right)
#if DEBUG
            recordGotoSplitMoveIfNeeded(direction: .right)
#endif
            return true
        }
        if matchConfiguredDirectionalShortcut(
            event: event,
            action: .focusUp,
            arrowGlyph: "↑",
            arrowKeyCode: 126
        ) || (ghosttyGotoSplitUpShortcut.map { matchDirectionalShortcut(event: event, shortcut: $0, arrowGlyph: "↑", arrowKeyCode: 126) } ?? false) {
            tabManager?.movePaneFocus(direction: .up)
#if DEBUG
            recordGotoSplitMoveIfNeeded(direction: .up)
#endif
            return true
        }
        if matchConfiguredDirectionalShortcut(
            event: event,
            action: .focusDown,
            arrowGlyph: "↓",
            arrowKeyCode: 125
        ) || (ghosttyGotoSplitDownShortcut.map { matchDirectionalShortcut(event: event, shortcut: $0, arrowGlyph: "↓", arrowKeyCode: 125) } ?? false) {
            tabManager?.movePaneFocus(direction: .down)
#if DEBUG
            recordGotoSplitMoveIfNeeded(direction: .down)
#endif
            return true
        }

        if matchConfiguredShortcut(event: event, action: .toggleSplitZoom) {
            _ = tabManager?.toggleFocusedSplitZoom()
#if DEBUG
            recordGotoSplitZoomIfNeeded()
#endif
            return true
        }

        // Split actions: Cmd+D / Cmd+Shift+D
        if matchConfiguredShortcut(event: event, action: .splitRight) {
#if DEBUG
            dlog("shortcut.action name=splitRight \(debugShortcutRouteSnapshot(event: event))")
#endif
            if shouldSuppressSplitShortcutForTransientTerminalFocusState(direction: .right) {
                return true
            }
            _ = performSplitShortcut(
                direction: .right,
                preferredWindow: event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
            )
            return true
        }

        if matchConfiguredShortcut(event: event, action: .splitDown) {
#if DEBUG
            dlog("shortcut.action name=splitDown \(debugShortcutRouteSnapshot(event: event))")
#endif
            if shouldSuppressSplitShortcutForTransientTerminalFocusState(direction: .down) {
                return true
            }
            _ = performSplitShortcut(
                direction: .down,
                preferredWindow: event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
            )
            return true
        }

        if matchConfiguredShortcut(event: event, action: .splitBrowserRight) {
#if DEBUG
            dlog("shortcut.action name=splitBrowserRight \(debugShortcutRouteSnapshot(event: event))")
#endif
            _ = performBrowserSplitShortcut(direction: .right)
            return true
        }

        if matchConfiguredShortcut(event: event, action: .splitBrowserDown) {
#if DEBUG
            dlog("shortcut.action name=splitBrowserDown \(debugShortcutRouteSnapshot(event: event))")
#endif
            _ = performBrowserSplitShortcut(direction: .down)
            return true
        }

        // Surface navigation (legacy Ctrl+Tab support)
        if matchTabShortcut(event: event, shortcut: StoredShortcut(key: "\t", command: false, shift: false, option: false, control: true)) {
            tabManager?.selectNextSurface()
            return true
        }
        if matchTabShortcut(event: event, shortcut: StoredShortcut(key: "\t", command: false, shift: true, option: false, control: true)) {
            tabManager?.selectPreviousSurface()
            return true
        }

        // New surface: Cmd+T
        if matchConfiguredShortcut(event: event, action: .newSurface) {
            tabManager?.newSurface()
            return true
        }

        // Open browser: Cmd+Shift+L
        if matchConfiguredShortcut(event: event, action: .openBrowser) {
            _ = openBrowserAndFocusAddressBar(insertAtEnd: true)
            return true
        }

        if matchConfiguredShortcut(event: event, action: .focusBrowserAddressBar) {
            if let focusedPanel = tabManager?.focusedBrowserPanel {
                focusBrowserAddressBar(in: focusedPanel)
                return true
            }

            if let browserAddressBarFocusedPanelId,
               focusBrowserAddressBar(panelId: browserAddressBarFocusedPanelId) {
                return true
            }

            if openBrowserAndFocusAddressBar(insertAtEnd: true) != nil {
                return true
            }
        }

        if matchConfiguredShortcut(event: event, action: .browserBack) {
            guard let focusedBrowserPanel = tabManager?.focusedBrowserPanel else {
                return false
            }
            focusedBrowserPanel.goBack()
            return true
        }

        if matchConfiguredShortcut(event: event, action: .browserForward) {
            guard let focusedBrowserPanel = tabManager?.focusedBrowserPanel else {
                return false
            }
            focusedBrowserPanel.goForward()
            return true
        }

        if matchConfiguredShortcut(event: event, action: .browserReload) {
            guard let focusedBrowserPanel = tabManager?.focusedBrowserPanel else {
                return false
            }
            focusedBrowserPanel.reload()
            return true
        }

        // Safari defaults:
        // - Option+Command+I => Show/Toggle Web Inspector
        // - Option+Command+C => Show JavaScript Console
        if matchConfiguredShortcut(event: event, action: .toggleBrowserDeveloperTools) {
#if DEBUG
            logDeveloperToolsShortcutSnapshot(phase: "toggle.pre", event: event)
#endif
            let didHandle = tabManager?.toggleDeveloperToolsFocusedBrowser() ?? false
#if DEBUG
            logDeveloperToolsShortcutSnapshot(phase: "toggle.post", event: event, didHandle: didHandle)
            DispatchQueue.main.async { [weak self] in
                self?.logDeveloperToolsShortcutSnapshot(phase: "toggle.tick", didHandle: didHandle)
            }
#endif
            if !didHandle { NSSound.beep() }
            return true
        }

        if matchConfiguredShortcut(event: event, action: .showBrowserJavaScriptConsole) {
#if DEBUG
            logDeveloperToolsShortcutSnapshot(phase: "console.pre", event: event)
#endif
            let didHandle = tabManager?.showJavaScriptConsoleFocusedBrowser() ?? false
#if DEBUG
            logDeveloperToolsShortcutSnapshot(phase: "console.post", event: event, didHandle: didHandle)
            DispatchQueue.main.async { [weak self] in
                self?.logDeveloperToolsShortcutSnapshot(phase: "console.tick", didHandle: didHandle)
            }
#endif
            if !didHandle { NSSound.beep() }
            return true
        }

        if matchConfiguredShortcut(event: event, action: .toggleReactGrab) {
            let didHandle = tabManager?.toggleReactGrabFromCurrentFocus() ?? false
            if !didHandle { NSSound.beep() }
            return true
        }

        if matchConfiguredShortcut(event: event, action: .browserZoomIn) {
            return tabManager?.zoomInFocusedBrowser() ?? false
        }

        if matchConfiguredShortcut(event: event, action: .browserZoomOut) {
            return tabManager?.zoomOutFocusedBrowser() ?? false
        }

        if matchConfiguredShortcut(event: event, action: .browserZoomReset) {
            return tabManager?.resetZoomFocusedBrowser() ?? false
        }

        if matchConfiguredShortcut(event: event, action: .find) {
            guard !shouldLetFocusedBrowserOwnFindShortcut(event) else {
                return false
            }
            tabManager?.startSearch()
            return true
        }

        if matchConfiguredShortcut(event: event, action: .findNext) {
            guard !shouldLetFocusedBrowserOwnFindShortcut(event) else {
                return false
            }
            tabManager?.findNext()
            return true
        }

        if matchConfiguredShortcut(event: event, action: .findPrevious) {
            guard !shouldLetFocusedBrowserOwnFindShortcut(event) else {
                return false
            }
            tabManager?.findPrevious()
            return true
        }

        if matchConfiguredShortcut(event: event, action: .hideFind) {
            guard !shouldLetFocusedBrowserOwnFindShortcut(event) else {
                return false
            }
            tabManager?.hideFind()
            return true
        }

        if matchConfiguredShortcut(event: event, action: .useSelectionForFind) {
            tabManager?.searchSelection()
            return true
        }

        if matchConfiguredShortcut(event: event, action: .reopenClosedBrowserPanel) {
            _ = tabManager?.reopenMostRecentlyClosedBrowserPanel()
            return true
        }

        return false
    }

    private func shouldSuppressSplitShortcutForTransientTerminalFocusState(direction: SplitDirection) -> Bool {
        guard let tabManager,
              let workspace = tabManager.selectedWorkspace,
              let focusedPanelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: focusedPanelId) else {
            return false
        }

        let hostedView = terminalPanel.hostedView
        let hostedSize = hostedView.bounds.size
        let hostedHiddenInHierarchy = hostedView.isHiddenOrHasHiddenAncestor
        let hostedAttachedToWindow = hostedView.window != nil
        let firstResponderIsWindow = NSApp.keyWindow?.firstResponder is NSWindow

        let shouldSuppress = shouldSuppressSplitShortcutForTransientTerminalFocusInputs(
            firstResponderIsWindow: firstResponderIsWindow,
            hostedSize: hostedSize,
            hostedHiddenInHierarchy: hostedHiddenInHierarchy,
            hostedAttachedToWindow: hostedAttachedToWindow
        )
        guard shouldSuppress else { return false }

        tabManager.reconcileFocusedPanelFromFirstResponderForKeyboard()

#if DEBUG
        let directionLabel: String
        switch direction {
        case .left: directionLabel = "left"
        case .right: directionLabel = "right"
        case .up: directionLabel = "up"
        case .down: directionLabel = "down"
        }
        let firstResponderType = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        dlog(
            "split.shortcut suppressed dir=\(directionLabel) reason=transient_focus_state " +
            "fr=\(firstResponderType) hidden=\(hostedHiddenInHierarchy ? 1 : 0) " +
            "attached=\(hostedAttachedToWindow ? 1 : 0) " +
            "frame=\(String(format: "%.1fx%.1f", hostedSize.width, hostedSize.height))"
        )
#endif
        return true
    }

#if DEBUG
    private func logBrowserZoomShortcutTrace(
        stage: String,
        event: NSEvent,
        flags: NSEvent.ModifierFlags,
        chars: String,
        action: BrowserZoomShortcutAction? = nil,
        handled: Bool? = nil
    ) {
        guard browserZoomShortcutTraceCandidate(
            flags: flags,
            chars: chars,
            keyCode: event.keyCode,
            literalChars: event.characters
        ) else {
            return
        }

        let keyWindow = NSApp.keyWindow
        let firstResponderType = keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let panel = tabManager?.focusedBrowserPanel
        let panelToken = panel.map { String($0.id.uuidString.prefix(8)) } ?? "nil"
        let panelZoom = panel?.webView.pageZoom ?? -1
        var line =
            "zoom.shortcut stage=\(stage) event=\(NSWindow.keyDescription(event)) " +
            "chars='\(chars)' flags=\(browserZoomShortcutTraceFlagsString(flags)) " +
            "action=\(browserZoomShortcutTraceActionString(action)) keyWin=\(keyWindow?.windowNumber ?? -1) " +
            "fr=\(firstResponderType) panel=\(panelToken) zoom=\(String(format: "%.3f", panelZoom)) " +
            "addrBarId=\(browserAddressBarFocusedPanelId?.uuidString.prefix(8) ?? "nil")"
        if let handled {
            line += " handled=\(handled ? 1 : 0)"
        }
        dlog(line)
    }

    private func browserFocusStateSnapshot() -> String {
        let selected = tabManager?.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        let focused = tabManager?.selectedWorkspace?.focusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        let addressBar = browserAddressBarFocusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        let keyWindow = NSApp.keyWindow?.windowNumber ?? -1
        let firstResponderType = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        return "selected=\(selected) focused=\(focused) addr=\(addressBar) keyWin=\(keyWindow) fr=\(firstResponderType)"
    }

    private func redactedDebugURL(_ url: URL?) -> String {
        guard let url else { return "nil" }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "<invalid>"
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? "<redacted>"
    }
#endif

    @discardableResult
    private func focusBrowserAddressBar(panelId: UUID) -> Bool {
        guard let tabManager,
              let workspace = tabManager.selectedWorkspace,
              let panel = workspace.browserPanel(for: panelId) else {
#if DEBUG
            dlog(
                "browser.focus.addressBar.route panel=\(panelId.uuidString.prefix(5)) " +
                "result=miss \(browserFocusStateSnapshot())"
            )
#endif
            return false
        }
#if DEBUG
        dlog(
            "browser.focus.addressBar.route panel=\(panel.id.uuidString.prefix(5)) " +
            "workspace=\(workspace.id.uuidString.prefix(5)) result=hit \(browserFocusStateSnapshot())"
        )
#endif
        workspace.focusPanel(panel.id)
#if DEBUG
        let focusedAfter = workspace.focusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        dlog(
            "browser.focus.addressBar.route panel=\(panel.id.uuidString.prefix(5)) " +
            "workspace=\(workspace.id.uuidString.prefix(5)) focusedAfter=\(focusedAfter)"
        )
#endif
        focusBrowserAddressBar(in: panel)
        return true
    }

    @discardableResult
    func openBrowserAndFocusAddressBar(url: URL? = nil, insertAtEnd: Bool = false) -> UUID? {
        let preferredProfileID =
            tabManager?.focusedBrowserPanel?.profileID
            ?? tabManager?.selectedWorkspace?.preferredBrowserProfileID
        guard let panelId = tabManager?.openBrowser(
            url: url,
            preferredProfileID: preferredProfileID,
            insertAtEnd: insertAtEnd
        ) else {
#if DEBUG
            dlog(
                "browser.focus.openAndFocus result=open_failed insertAtEnd=\(insertAtEnd ? 1 : 0) " +
                "url=\(redactedDebugURL(url)) \(browserFocusStateSnapshot())"
            )
#endif
            return nil
        }
#if DEBUG
        dlog(
            "browser.focus.openAndFocus result=open_ok panel=\(panelId.uuidString.prefix(5)) " +
            "insertAtEnd=\(insertAtEnd ? 1 : 0) url=\(redactedDebugURL(url))"
        )
#endif
#if DEBUG
        let didFocus = focusBrowserAddressBar(panelId: panelId)
        dlog(
            "browser.focus.openAndFocus result=focus_request panel=\(panelId.uuidString.prefix(5)) " +
            "focused=\(didFocus ? 1 : 0) \(browserFocusStateSnapshot())"
        )
#else
        _ = focusBrowserAddressBar(panelId: panelId)
#endif
        return panelId
    }

    private func focusBrowserAddressBar(in panel: BrowserPanel) {
#if DEBUG
        let requestId = panel.requestAddressBarFocus()
        dlog(
            "browser.focus.addressBar.request panel=\(panel.id.uuidString.prefix(5)) " +
            "request=\(requestId.uuidString.prefix(8)) \(browserFocusStateSnapshot())"
        )
#else
        _ = panel.requestAddressBarFocus()
#endif
        browserAddressBarFocusedPanelId = panel.id
#if DEBUG
        dlog(
            "browser.focus.addressBar.sticky panel=\(panel.id.uuidString.prefix(5)) " +
            "request=\(requestId.uuidString.prefix(8)) \(browserFocusStateSnapshot())"
        )
#endif
        NotificationCenter.default.post(name: .browserFocusAddressBar, object: panel.id)
#if DEBUG
        dlog(
            "browser.focus.addressBar.notify panel=\(panel.id.uuidString.prefix(5)) " +
            "request=\(requestId.uuidString.prefix(8))"
        )
#endif
    }

    func focusedBrowserAddressBarPanelId() -> UUID? {
        browserAddressBarFocusedPanelId
    }

    private func focusedBrowserAddressBarPanelIdForShortcutEvent(_ event: NSEvent) -> UUID? {
        guard let panelId = browserAddressBarFocusedPanelId else { return nil }

        guard let context = preferredMainWindowContextForShortcutRouting(event: event) else {
#if DEBUG
            dlog(
                "browser.focus.addressBar.shortcutContext panel=\(panelId.uuidString.prefix(5)) " +
                "accepted=0 reason=no_context event=\(NSWindow.keyDescription(event))"
            )
#endif
            return nil
        }

        guard let workspace = context.tabManager.selectedWorkspace else {
#if DEBUG
            dlog(
                "browser.focus.addressBar.shortcutContext panel=\(panelId.uuidString.prefix(5)) " +
                "accepted=0 reason=no_workspace event=\(NSWindow.keyDescription(event))"
            )
#endif
            return nil
        }

        guard let panel = workspace.browserPanel(for: panelId) else {
#if DEBUG
            dlog(
                "browser.focus.addressBar.shortcutContext panel=\(panelId.uuidString.prefix(5)) " +
                "accepted=0 reason=panel_not_in_workspace workspace=\(workspace.id.uuidString.prefix(5)) " +
                "event=\(NSWindow.keyDescription(event))"
            )
#endif
            return nil
        }

        let shortcutWindow = resolvedShortcutEventWindow(event) ?? NSApp.keyWindow ?? NSApp.mainWindow
        let shortcutResponder = shortcutWindow?.firstResponder

        guard isBrowserOmnibarResponder(shortcutResponder) else {
#if DEBUG
            let focusedPanel = workspace.focusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
            dlog(
                "browser.focus.addressBar.shortcutContext panel=\(panelId.uuidString.prefix(5)) " +
                "accepted=0 reason=responder_not_omnibar responder=\(shortcutResponder.map { String(describing: type(of: $0)) } ?? "nil") " +
                "pending=\(panel.pendingAddressBarFocusRequestId != nil ? 1 : 0) focusedPanel=\(focusedPanel) " +
                "event=\(NSWindow.keyDescription(event))"
            )
#endif
            return nil
        }

#if DEBUG
        dlog(
            "browser.focus.addressBar.shortcutContext panel=\(panelId.uuidString.prefix(5)) " +
            "accepted=1 reason=omnibar_responder workspace=\(workspace.id.uuidString.prefix(5)) " +
            "event=\(NSWindow.keyDescription(event))"
        )
#endif
        return panelId
    }

    private func browserOmnibarOwnerView(for responder: NSResponder?) -> NSView? {
        guard let responder else { return nil }

        if let textView = responder as? NSTextView,
           textView.isFieldEditor,
           let delegateView = textView.delegate as? NSView,
           delegateView.identifier == browserOmnibarTextFieldIdentifier {
            return delegateView
        }

        let ownerView = keyRoutingOwnerView(for: responder)
        guard ownerView?.identifier == browserOmnibarTextFieldIdentifier else { return nil }
        return ownerView
    }

    private func isBrowserOmnibarResponder(_ responder: NSResponder?) -> Bool {
        guard let ownerView = browserOmnibarOwnerView(for: responder) else { return false }

        if let fieldEditor = responder as? NSTextView,
           fieldEditor.isFieldEditor {
            return (ownerView as? NSTextField)?.currentEditor() === fieldEditor
        }

        return true
    }

    private func shouldPreserveBrowserAddressBarTracking(for panel: BrowserPanel) -> Bool {
        guard browserAddressBarFocusedPanelId == panel.id else { return false }
        if isBrowserOmnibarResponder(panel.webView.window?.firstResponder) {
            return true
        }
        return panel.preferredFocusIntent == .addressBar && panel.shouldSuppressWebViewFocus()
    }

    @discardableResult
    func requestBrowserAddressBarFocus(panelId: UUID) -> Bool {
        focusBrowserAddressBar(panelId: panelId)
    }

    private func shouldBypassAppShortcutForFocusedBrowserAddressBar(
        flags: NSEvent.ModifierFlags,
        chars: String
    ) -> Bool {
        guard browserAddressBarFocusedPanelId != nil else { return false }
        let normalizedFlags = browserOmnibarNormalizedModifierFlags(flags)
        let isCommandOrControlOnly = normalizedFlags == [.command] || normalizedFlags == [.control]
        guard isCommandOrControlOnly else { return false }
        let shouldBypass = chars == "n" || chars == "p"
#if DEBUG
        if shouldBypass {
            let panelToken = browserAddressBarFocusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
            dlog(
                "browser.focus.addressBar.shortcutBypass panel=\(panelToken) " +
                "chars=\(chars) flags=\(normalizedFlags.rawValue)"
            )
        }
#endif
        return shouldBypass
    }

    private func commandOmnibarSelectionDelta(
        hasFocusedAddressBar: Bool,
        flags: NSEvent.ModifierFlags,
        chars: String
    ) -> Int? {
        browserOmnibarSelectionDeltaForCommandNavigation(
            hasFocusedAddressBar: hasFocusedAddressBar,
            flags: flags,
            chars: chars
        )
    }

    private func dispatchBrowserOmnibarSelectionMove(delta: Int) {
        guard delta != 0 else { return }
        guard let panelId = browserAddressBarFocusedPanelId else { return }
#if DEBUG
        dlog(
            "browser.focus.omnibar.selectionMove panel=\(panelId.uuidString.prefix(5)) " +
            "delta=\(delta) repeatKey=\(browserOmnibarRepeatKeyCode.map(String.init) ?? "nil")"
        )
#endif
        NotificationCenter.default.post(
            name: .browserMoveOmnibarSelection,
            object: panelId,
            userInfo: ["delta": delta]
        )
    }

    private func startBrowserOmnibarSelectionRepeatIfNeeded(keyCode: UInt16, delta: Int) {
        guard delta != 0 else { return }
        guard browserAddressBarFocusedPanelId != nil else {
#if DEBUG
            dlog(
                "browser.focus.omnibar.repeat.start key=\(keyCode) delta=\(delta) " +
                "result=skip_no_focused_address_bar"
            )
#endif
            return
        }

        if browserOmnibarRepeatKeyCode == keyCode, browserOmnibarRepeatDelta == delta {
#if DEBUG
            let panelToken = browserAddressBarFocusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
            dlog(
                "browser.focus.omnibar.repeat.start panel=\(panelToken) " +
                "key=\(keyCode) delta=\(delta) result=reuse"
            )
#endif
            return
        }

        stopBrowserOmnibarSelectionRepeat()
        browserOmnibarRepeatKeyCode = keyCode
        browserOmnibarRepeatDelta = delta
#if DEBUG
        let panelToken = browserAddressBarFocusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        dlog(
            "browser.focus.omnibar.repeat.start panel=\(panelToken) " +
            "key=\(keyCode) delta=\(delta) result=armed"
        )
#endif

        let start = DispatchWorkItem { [weak self] in
            self?.scheduleBrowserOmnibarSelectionRepeatTick()
        }
        browserOmnibarRepeatStartWorkItem = start
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: start)
    }

    private func scheduleBrowserOmnibarSelectionRepeatTick() {
        browserOmnibarRepeatStartWorkItem = nil
        guard browserAddressBarFocusedPanelId != nil else {
#if DEBUG
            dlog("browser.focus.omnibar.repeat.tick result=stop_no_focused_address_bar")
#endif
            stopBrowserOmnibarSelectionRepeat()
            return
        }
        guard browserOmnibarRepeatKeyCode != nil else { return }

#if DEBUG
        let panelToken = browserAddressBarFocusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        dlog(
            "browser.focus.omnibar.repeat.tick panel=\(panelToken) " +
            "delta=\(browserOmnibarRepeatDelta)"
        )
#endif
        dispatchBrowserOmnibarSelectionMove(delta: browserOmnibarRepeatDelta)

        let tick = DispatchWorkItem { [weak self] in
            self?.scheduleBrowserOmnibarSelectionRepeatTick()
        }
        browserOmnibarRepeatTickWorkItem = tick
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.055, execute: tick)
    }

    private func stopBrowserOmnibarSelectionRepeat() {
#if DEBUG
        let previousKeyCode = browserOmnibarRepeatKeyCode
        let previousDelta = browserOmnibarRepeatDelta
#endif
        browserOmnibarRepeatStartWorkItem?.cancel()
        browserOmnibarRepeatTickWorkItem?.cancel()
        browserOmnibarRepeatStartWorkItem = nil
        browserOmnibarRepeatTickWorkItem = nil
        browserOmnibarRepeatKeyCode = nil
        browserOmnibarRepeatDelta = 0
#if DEBUG
        if previousKeyCode != nil || previousDelta != 0 {
            dlog(
                "browser.focus.omnibar.repeat.stop key=\(previousKeyCode.map(String.init) ?? "nil") " +
                "delta=\(previousDelta)"
            )
        }
#endif
    }

    private func handleBrowserOmnibarSelectionRepeatLifecycleEvent(_ event: NSEvent) {
        guard browserOmnibarRepeatKeyCode != nil else { return }

        switch event.type {
        case .keyUp:
            if event.keyCode == browserOmnibarRepeatKeyCode {
#if DEBUG
                dlog(
                    "browser.focus.omnibar.repeat.lifecycle event=keyUp key=\(event.keyCode) " +
                    "action=stop"
                )
#endif
                stopBrowserOmnibarSelectionRepeat()
            }
        case .flagsChanged:
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !flags.contains(.command) {
#if DEBUG
                dlog(
                    "browser.focus.omnibar.repeat.lifecycle event=flagsChanged " +
                    "flags=\(flags.rawValue) action=stop"
                )
#endif
                stopBrowserOmnibarSelectionRepeat()
            }
        default:
            break
        }
    }

    private func isLikelyWebInspectorResponder(_ responder: NSResponder?) -> Bool {
        cmuxIsLikelyWebInspectorResponder(responder)
    }

#if DEBUG
    private func developerToolsShortcutProbeKind(event: NSEvent) -> String? {
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .toggleBrowserDeveloperTools)) {
            return "toggle.configured"
        }
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .showBrowserJavaScriptConsole)) {
            return "console.configured"
        }

        let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.command, .option] {
            if chars == "i" || event.keyCode == 34 {
                return "toggle.literal"
            }
            if chars == "c" || event.keyCode == 8 {
                return "console.literal"
            }
        }
        return nil
    }

    private func logDeveloperToolsShortcutSnapshot(
        phase: String,
        event: NSEvent? = nil,
        didHandle: Bool? = nil
    ) {
        let keyWindow = NSApp.keyWindow
        let firstResponder = keyWindow?.firstResponder
        let firstResponderType = firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let firstResponderPtr = firstResponder.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
        let eventDescription = event.map(NSWindow.keyDescription) ?? "none"
        if let browser = tabManager?.focusedBrowserPanel {
            var line =
                "browser.devtools shortcut=\(phase) panel=\(browser.id.uuidString.prefix(5)) " +
                "\(browser.debugDeveloperToolsStateSummary()) \(browser.debugDeveloperToolsGeometrySummary()) " +
                "keyWin=\(keyWindow?.windowNumber ?? -1) fr=\(firstResponderType)@\(firstResponderPtr) event=\(eventDescription)"
            if let didHandle {
                line += " handled=\(didHandle ? 1 : 0)"
            }
            dlog(line)
            return
        }
        var line =
            "browser.devtools shortcut=\(phase) panel=nil keyWin=\(keyWindow?.windowNumber ?? -1) " +
            "fr=\(firstResponderType)@\(firstResponderPtr) event=\(eventDescription)"
        if let didHandle {
            line += " handled=\(didHandle ? 1 : 0)"
        }
        dlog(line)
    }
#endif

    private func prepareFocusedBrowserDevToolsForSplit(directionLabel: String) {
        guard let browser = tabManager?.focusedBrowserPanel else { return }
        guard browser.shouldPreserveWebViewAttachmentDuringTransientHide() else { return }
        guard let keyWindow = NSApp.keyWindow else { return }
        guard isLikelyWebInspectorResponder(keyWindow.firstResponder) else { return }

        let beforeResponder = keyWindow.firstResponder
        let movedToWebView = keyWindow.makeFirstResponder(browser.webView)
        let movedToNil = movedToWebView ? false : keyWindow.makeFirstResponder(nil)

        #if DEBUG
        let beforeType = beforeResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let beforePtr = beforeResponder.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
        let afterResponder = keyWindow.firstResponder
        let afterType = afterResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let afterPtr = afterResponder.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
        dlog(
            "split.shortcut inspector.preflight dir=\(directionLabel) panel=\(browser.id.uuidString.prefix(5)) " +
            "before=\(beforeType)@\(beforePtr) after=\(afterType)@\(afterPtr) " +
            "moveWeb=\(movedToWebView ? 1 : 0) moveNil=\(movedToNil ? 1 : 0) \(browser.debugDeveloperToolsStateSummary())"
        )
        #endif
    }

    @discardableResult
    func performSplitShortcut(direction: SplitDirection, preferredWindow: NSWindow? = nil) -> Bool {
        let targetWindow = preferredWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        let terminalContext = focusedTerminalShortcutContext(preferredWindow: targetWindow)
        _ = synchronizeActiveMainWindowContext(preferredWindow: targetWindow)

        let directionLabel: String
        switch direction {
        case .left: directionLabel = "left"
        case .right: directionLabel = "right"
        case .up: directionLabel = "up"
        case .down: directionLabel = "down"
        }

        #if DEBUG
        let keyWindow = NSApp.keyWindow
        let firstResponder = keyWindow?.firstResponder
        let firstResponderType = firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let firstResponderPtr = firstResponder.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
        let firstResponderWindow: Int = {
            if let v = firstResponder as? NSView {
                return v.window?.windowNumber ?? -1
            }
            if let w = firstResponder as? NSWindow {
                return w.windowNumber
            }
            return -1
        }()
        let splitContext = "keyWin=\(keyWindow?.windowNumber ?? -1) mainWin=\(NSApp.mainWindow?.windowNumber ?? -1) fr=\(firstResponderType)@\(firstResponderPtr) frWin=\(firstResponderWindow)"
        if let browser = tabManager?.focusedBrowserPanel {
            let webWindow = browser.webView.window?.windowNumber ?? -1
            let webSuperview = browser.webView.superview.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
            dlog("split.shortcut dir=\(directionLabel) pre panel=\(browser.id.uuidString.prefix(5)) \(browser.debugDeveloperToolsStateSummary()) webWin=\(webWindow) webSuper=\(webSuperview) \(splitContext)")
        } else {
            dlog("split.shortcut dir=\(directionLabel) pre panel=nil \(splitContext)")
        }
        #endif

        prepareFocusedBrowserDevToolsForSplit(directionLabel: directionLabel)
        let didCreateSplit: Bool = {
            if let terminalContext {
                return terminalContext.tabManager.createSplit(
                    tabId: terminalContext.workspaceId,
                    surfaceId: terminalContext.panelId,
                    direction: direction
                ) != nil
            }
            return tabManager?.createSplit(direction: direction) != nil
        }()
#if DEBUG
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            let keyWindow = NSApp.keyWindow
            let firstResponder = keyWindow?.firstResponder
            let firstResponderType = firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            let firstResponderPtr = firstResponder.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
            let firstResponderWindow: Int = {
                if let v = firstResponder as? NSView {
                    return v.window?.windowNumber ?? -1
                }
                if let w = firstResponder as? NSWindow {
                    return w.windowNumber
                }
                return -1
            }()
            let splitContext = "keyWin=\(keyWindow?.windowNumber ?? -1) mainWin=\(NSApp.mainWindow?.windowNumber ?? -1) fr=\(firstResponderType)@\(firstResponderPtr) frWin=\(firstResponderWindow)"
            if let browser = self?.tabManager?.focusedBrowserPanel {
                let webWindow = browser.webView.window?.windowNumber ?? -1
                let webSuperview = browser.webView.superview.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
                dlog("split.shortcut dir=\(directionLabel) post panel=\(browser.id.uuidString.prefix(5)) \(browser.debugDeveloperToolsStateSummary()) webWin=\(webWindow) webSuper=\(webSuperview) \(splitContext)")
            } else {
                dlog("split.shortcut dir=\(directionLabel) post panel=nil \(splitContext)")
            }
        }
        recordGotoSplitSplitIfNeeded(direction: direction)
#endif
        return didCreateSplit
    }

    @discardableResult
    func performBrowserSplitShortcut(direction: SplitDirection) -> Bool {
        _ = synchronizeActiveMainWindowContext(preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow)

        #if DEBUG
        let directionLabel: String
        switch direction {
        case .left: directionLabel = "left"
        case .right: directionLabel = "right"
        case .up: directionLabel = "up"
        case .down: directionLabel = "down"
        }
        let selectedTabBefore = tabManager?.selectedTabId?.uuidString.prefix(5) ?? "nil"
        let focusedPanelBefore = tabManager?.selectedWorkspace?.focusedPanelId?.uuidString.prefix(5) ?? "nil"
        dlog(
            "split.browser.shortcut pre dir=\(directionLabel) " +
            "tab=\(selectedTabBefore) focusedPanel=\(focusedPanelBefore)"
        )
        #endif

        guard let panelId = tabManager?.createBrowserSplit(direction: direction) else {
            #if DEBUG
            dlog("split.browser.shortcut failed dir=\(directionLabel)")
            #endif
            return false
        }

        #if DEBUG
        let selectedTabAfter = tabManager?.selectedTabId?.uuidString.prefix(5) ?? "nil"
        let focusedPanelAfter = tabManager?.selectedWorkspace?.focusedPanelId?.uuidString.prefix(5) ?? "nil"
        dlog(
            "split.browser.shortcut post dir=\(directionLabel) " +
            "created=\(panelId.uuidString.prefix(5)) tab=\(selectedTabAfter) focusedPanel=\(focusedPanelAfter)"
        )
        #endif

        _ = focusBrowserAddressBar(panelId: panelId)
        return true
    }

    /// Allow AppKit-backed browser surfaces (WKWebView) to route non-menu shortcuts
    /// through the same app-level shortcut handler used by the local key monitor.
    @discardableResult
    func handleBrowserSurfaceKeyEquivalent(_ event: NSEvent) -> Bool {
        handleCustomShortcut(event: event)
    }

    @discardableResult
    func requestRenameWorkspaceViaCommandPalette(preferredWindow: NSWindow? = nil) -> Bool {
        let targetWindow = preferredWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        requestCommandPaletteRenameWorkspace(
            preferredWindow: targetWindow,
            source: "shortcut.renameWorkspace"
        )
        return true
    }

    @discardableResult
    func requestEditWorkspaceDescriptionViaCommandPalette(preferredWindow: NSWindow? = nil) -> Bool {
        let targetWindow = preferredWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
#if DEBUG
        dlog(
            "shortcut.editWorkspaceDescription request target={\(debugWindowToken(targetWindow))} " +
            "fr=\(targetWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")"
        )
#endif
        requestCommandPaletteEditWorkspaceDescription(
            preferredWindow: targetWindow,
            source: "shortcut.editWorkspaceDescription"
        )
        return true
    }

#if DEBUG
    // Debug/test hook: allow socket-driven shortcut simulation to reuse the same shortcut routing
    // logic as the local NSEvent monitor, without relying on AppKit event monitor behavior for
    // synthetic NSEvents.
    func debugHandleCustomShortcut(event: NSEvent) -> Bool {
        handleCustomShortcut(event: event)
    }

    // Debug/test hook: mirrors local monitor routing (keyDown + keyUp lifecycle).
    func debugHandleShortcutMonitorEvent(event: NSEvent) -> Bool {
        if event.type == .keyDown {
            return handleCustomShortcut(event: event)
        }
        handleBrowserOmnibarSelectionRepeatLifecycleEvent(event)
        return clearEscapeSuppressionForKeyUp(event: event, consumeIfSuppressed: true)
    }

    func debugMarkCommandPaletteOpenPending(window: NSWindow) {
        markCommandPaletteOpenRequested(for: window)
    }

    @discardableResult
    func debugSetCommandPalettePendingOpenAge(window: NSWindow, age: TimeInterval) -> Bool {
        guard let windowId = mainWindowId(for: window) else { return false }
        commandPalettePendingOpenByWindowId[windowId] = true
        commandPaletteRecentRequestAtByWindowId[windowId] = ProcessInfo.processInfo.systemUptime - max(age, 0)
        return true
    }

    // Test hook: remap a window context under a detached window key so direct
    // ObjectIdentifier(window) lookups fail and fallback logic is exercised.
    @discardableResult
    func debugInjectWindowContextKeyMismatch(windowId: UUID) -> Bool {
        guard let context = mainWindowContexts.values.first(where: { $0.windowId == windowId }),
              let window = context.window ?? windowForMainWindowId(windowId) else {
            return false
        }

        let detachedWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 16, height: 16),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        debugDetachedContextWindows.append(detachedWindow)

        let contextKeys = mainWindowContexts.compactMap { key, value in
            value === context ? key : nil
        }
        for key in contextKeys {
            mainWindowContexts.removeValue(forKey: key)
        }
        mainWindowContexts[ObjectIdentifier(detachedWindow)] = context
        context.window = window
        return true
    }
#endif

    private func findButton(in view: NSView, titled title: String) -> NSButton? {
        if let button = view as? NSButton, button.title == title {
            return button
        }
        for subview in view.subviews {
            if let found = findButton(in: subview, titled: title) {
                return found
            }
        }
        return nil
    }

    private func findStaticText(in view: NSView, equals text: String) -> Bool {
        if let field = view as? NSTextField, field.stringValue == text {
            return true
        }
        for subview in view.subviews {
            if findStaticText(in: subview, equals: text) {
                return true
            }
        }
        return false
    }

    private func matchConfiguredShortcut(event: NSEvent, action: KeyboardShortcutSettings.Action) -> Bool {
        let shortcut = KeyboardShortcutSettings.shortcut(for: action)
        if let prefix = activeConfiguredShortcutChordPrefixForCurrentEvent {
            guard let secondStroke = shortcut.secondStroke,
                  shortcut.firstStroke == prefix else {
                return false
            }
            return matchShortcutStroke(event: event, stroke: secondStroke)
        }
        guard !shortcut.hasChord else { return false }
        return matchShortcutStroke(event: event, stroke: shortcut.firstStroke)
    }

    private func numberedConfiguredShortcutDigit(
        event: NSEvent,
        action: KeyboardShortcutSettings.Action
    ) -> Int? {
        let shortcut = KeyboardShortcutSettings.shortcut(for: action)
        if let prefix = activeConfiguredShortcutChordPrefixForCurrentEvent {
            guard let secondStroke = shortcut.secondStroke,
                  shortcut.firstStroke == prefix else {
                return nil
            }
            return numberedShortcutDigit(event: event, stroke: secondStroke)
        }
        guard !shortcut.hasChord else { return nil }
        return numberedShortcutDigit(event: event, stroke: shortcut.firstStroke)
    }

    private func matchConfiguredDirectionalShortcut(
        event: NSEvent,
        action: KeyboardShortcutSettings.Action,
        arrowGlyph: String,
        arrowKeyCode: UInt16
    ) -> Bool {
        let shortcut = KeyboardShortcutSettings.shortcut(for: action)
        if let prefix = activeConfiguredShortcutChordPrefixForCurrentEvent {
            guard let secondStroke = shortcut.secondStroke,
                  shortcut.firstStroke == prefix else {
                return false
            }
            return matchDirectionalShortcut(
                event: event,
                stroke: secondStroke,
                arrowGlyph: arrowGlyph,
                arrowKeyCode: arrowKeyCode
            )
        }
        guard !shortcut.hasChord else { return false }
        return matchDirectionalShortcut(
            event: event,
            stroke: shortcut.firstStroke,
            arrowGlyph: arrowGlyph,
            arrowKeyCode: arrowKeyCode
        )
    }

    private func configuredShortcutChordWindowNumber(for event: NSEvent) -> Int? {
        if let window = mainWindowForShortcutEvent(event) {
            return window.windowNumber
        }
        if let window = event.window {
            return window.windowNumber
        }
        return event.windowNumber > 0 ? event.windowNumber : nil
    }

    private func armConfiguredShortcutChordIfNeeded(
        event: NSEvent,
        actions: [KeyboardShortcutSettings.Action]? = nil
    ) -> Bool {
        for action in actions ?? configuredShortcutChordActions {
            let shortcut = KeyboardShortcutSettings.shortcut(for: action)
            guard shortcut.hasChord else { continue }
            if matchShortcutStroke(event: event, stroke: shortcut.firstStroke) {
                pendingConfiguredShortcutChord = PendingConfiguredShortcutChord(
                    firstStroke: shortcut.firstStroke,
                    windowNumber: configuredShortcutChordWindowNumber(for: event)
                )
                return true
            }
        }
        return false
    }

    /// Match a shortcut stroke against an event, handling normal keys.
    private func matchShortcutStroke(event: NSEvent, stroke: ShortcutStroke) -> Bool {
        stroke.matches(event: event, layoutCharacterProvider: shortcutLayoutCharacterProvider)
    }

    private func matchShortcut(event: NSEvent, shortcut: StoredShortcut) -> Bool {
        shortcut.matches(event: event, layoutCharacterProvider: shortcutLayoutCharacterProvider)
    }

    private func numberedShortcutDigit(event: NSEvent, stroke: ShortcutStroke) -> Int? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        guard flags == stroke.modifierFlags else { return nil }
        let numberKeyDigit = digitForNumberKeyCode(event.keyCode)

        if let digit = numberedShortcutDigit(
            eventCharacter: event.charactersIgnoringModifiers,
            applyShiftSymbolNormalization: flags.contains(.shift),
            eventKeyCode: event.keyCode
        ) {
            return digit
        }

        let eventCharsIgnoringModifiers = event.charactersIgnoringModifiers
        let hasUsableASCIIEventChars = !(eventCharsIgnoringModifiers?.isEmpty ?? true)
            && (eventCharsIgnoringModifiers?.allSatisfy(\.isASCII) ?? true)
        if !hasUsableASCIIEventChars || numberKeyDigit != nil {
            let layoutCharacter = shortcutLayoutCharacterProvider(event.keyCode, event.modifierFlags)
            if let digit = numberedShortcutDigit(
                eventCharacter: layoutCharacter,
                applyShiftSymbolNormalization: false,
                eventKeyCode: event.keyCode
            ) {
                return digit
            }
        }

        return numberKeyDigit
    }

    private func numberedShortcutDigit(event: NSEvent, shortcut: StoredShortcut) -> Int? {
        guard !shortcut.hasChord else { return nil }
        return numberedShortcutDigit(event: event, stroke: shortcut.firstStroke)
    }

    private func numberedShortcutDigit(
        eventCharacter: String?,
        applyShiftSymbolNormalization: Bool,
        eventKeyCode: UInt16
    ) -> Int? {
        guard let eventCharacter, !eventCharacter.isEmpty else { return nil }
        let normalized = normalizedShortcutEventCharacter(
            eventCharacter,
            applyShiftSymbolNormalization: applyShiftSymbolNormalization,
            eventKeyCode: eventKeyCode
        )
        guard let digit = Int(normalized), (1...9).contains(digit) else { return nil }
        return digit
    }

    private func normalizedShortcutEventCharacter(
        _ eventCharacter: String,
        applyShiftSymbolNormalization: Bool,
        eventKeyCode: UInt16
    ) -> String {
        let lowered = eventCharacter.lowercased()
        guard applyShiftSymbolNormalization else { return lowered }

        switch lowered {
        case "{": return "["
        case "}": return "]"
        case "<": return eventKeyCode == 43 ? "," : lowered // kVK_ANSI_Comma
        case ">": return eventKeyCode == 47 ? "." : lowered // kVK_ANSI_Period
        case "?": return "/"
        case ":": return ";"
        case "\"": return "'"
        case "|": return "\\"
        case "~": return "`"
        case "+": return "="
        case "_": return "-"
        case "!": return eventKeyCode == 18 ? "1" : lowered // kVK_ANSI_1
        case "@": return eventKeyCode == 19 ? "2" : lowered // kVK_ANSI_2
        case "#": return eventKeyCode == 20 ? "3" : lowered // kVK_ANSI_3
        case "$": return eventKeyCode == 21 ? "4" : lowered // kVK_ANSI_4
        case "%": return eventKeyCode == 23 ? "5" : lowered // kVK_ANSI_5
        case "^": return eventKeyCode == 22 ? "6" : lowered // kVK_ANSI_6
        case "&": return eventKeyCode == 26 ? "7" : lowered // kVK_ANSI_7
        case "*": return eventKeyCode == 28 ? "8" : lowered // kVK_ANSI_8
        case "(": return eventKeyCode == 25 ? "9" : lowered // kVK_ANSI_9
        case ")": return eventKeyCode == 29 ? "0" : lowered // kVK_ANSI_0
        default: return lowered
        }
    }

    private func digitForNumberKeyCode(_ keyCode: UInt16) -> Int? {
        switch keyCode {
        case 18: return 1 // kVK_ANSI_1
        case 19: return 2 // kVK_ANSI_2
        case 20: return 3 // kVK_ANSI_3
        case 21: return 4 // kVK_ANSI_4
        case 23: return 5 // kVK_ANSI_5
        case 22: return 6 // kVK_ANSI_6
        case 26: return 7 // kVK_ANSI_7
        case 28: return 8 // kVK_ANSI_8
        case 25: return 9 // kVK_ANSI_9
        default:
            return nil
        }
    }

    /// Match arrow key shortcuts using keyCode
    /// Arrow keys include .numericPad and .function in their modifierFlags, so strip those before comparing.
    private func matchArrowShortcut(event: NSEvent, stroke: ShortcutStroke, keyCode: UInt16) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function])
        return event.keyCode == keyCode && flags == stroke.modifierFlags
    }

    /// Match tab key shortcuts using keyCode 48
    private func matchTabShortcut(event: NSEvent, stroke: ShortcutStroke) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return event.keyCode == 48 && flags == stroke.modifierFlags
    }

    private func matchTabShortcut(event: NSEvent, shortcut: StoredShortcut) -> Bool {
        guard !shortcut.hasChord else { return false }
        return matchTabShortcut(event: event, stroke: shortcut.firstStroke)
    }

    /// Directional shortcuts default to arrow keys, but the shortcut recorder only supports letter/number keys.
    /// Support both so users can customize pane navigation (e.g. Cmd+Ctrl+H/J/K/L).
    private func matchDirectionalShortcut(
        event: NSEvent,
        stroke: ShortcutStroke,
        arrowGlyph: String,
        arrowKeyCode: UInt16
    ) -> Bool {
        if stroke.key == arrowGlyph {
            return matchArrowShortcut(event: event, stroke: stroke, keyCode: arrowKeyCode)
        }
        return matchShortcutStroke(event: event, stroke: stroke)
    }

    private func matchDirectionalShortcut(
        event: NSEvent,
        shortcut: StoredShortcut,
        arrowGlyph: String,
        arrowKeyCode: UInt16
    ) -> Bool {
        guard !shortcut.hasChord else { return false }
        return matchDirectionalShortcut(
            event: event,
            stroke: shortcut.firstStroke,
            arrowGlyph: arrowGlyph,
            arrowKeyCode: arrowKeyCode
        )
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        updateController.validateMenuItem(item)
    }


    private func configureUserNotifications() {
        let actions = [
            UNNotificationAction(
                identifier: TerminalNotificationStore.actionShowIdentifier,
                title: "Show"
            )
        ]

        let category = UNNotificationCategory(
            identifier: TerminalNotificationStore.categoryIdentifier,
            actions: actions,
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([category])
        center.delegate = self
    }

    private func disableNativeTabbingShortcut() {
        guard let menu = NSApp.mainMenu else { return }
        disableMenuItemShortcut(in: menu, action: #selector(NSWindow.toggleTabBar(_:)))
    }

    private func disableMenuItemShortcut(in menu: NSMenu, action: Selector) {
        for item in menu.items {
            if item.action == action {
                item.keyEquivalent = ""
                item.keyEquivalentModifierMask = []
                item.isEnabled = false
            }
            if let submenu = item.submenu {
                disableMenuItemShortcut(in: submenu, action: action)
            }
        }
    }

    private func ensureApplicationIcon() {
        let mode = AppIconSettings.resolvedMode()
        AppIconSettings.applyIcon(mode)
    }

    private func scheduleLaunchServicesBundleRegistration(
        bundleURL: URL = Bundle.main.bundleURL.standardizedFileURL,
        scheduler: @escaping (@escaping @Sendable () -> Void) -> Void = AppDelegate.enqueueLaunchServicesRegistrationWork,
        register: @escaping (CFURL) -> OSStatus = { url in
            LSRegisterURL(url, true)
        },
        breadcrumb: @escaping (_ message: String, _ data: [String: Any]) -> Void = { message, data in
            sentryBreadcrumb(message, category: "startup", data: data)
        }
    ) {
        let normalizedURL = bundleURL.standardizedFileURL
        breadcrumb("launchservices.register.schedule", [
            "bundlePath": normalizedURL.path
        ])

        scheduler {
            let startedAt = CFAbsoluteTimeGetCurrent()
            let registerStatus = register(normalizedURL as CFURL)
            let durationMs = Int(((CFAbsoluteTimeGetCurrent() - startedAt) * 1000).rounded())

            breadcrumb("launchservices.register.complete", [
                "bundlePath": normalizedURL.path,
                "status": Int(registerStatus),
                "durationMs": durationMs
            ])

            if registerStatus != noErr {
                NSLog("LaunchServices registration failed (status: \(registerStatus)) for \(normalizedURL.path)")
            }
        }
    }

#if DEBUG
    func scheduleLaunchServicesBundleRegistrationForTesting(
        bundleURL: URL,
        scheduler: @escaping (@escaping @Sendable () -> Void) -> Void,
        register: @escaping (CFURL) -> OSStatus,
        breadcrumb: @escaping (_ message: String, _ data: [String: Any]) -> Void = { _, _ in }
    ) {
        scheduleLaunchServicesBundleRegistration(
            bundleURL: bundleURL,
            scheduler: scheduler,
            register: register,
            breadcrumb: breadcrumb
        )
    }
#endif

    private func enforceSingleInstance() {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        let currentPid = ProcessInfo.processInfo.processIdentifier

        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleId) {
            guard app.processIdentifier != currentPid else { continue }
            app.terminate()
            if !app.isTerminated {
                _ = app.forceTerminate()
            }
        }
    }

    private func observeDuplicateLaunches() {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        let embeddedCLIURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/bin/cmux", isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let currentPid = ProcessInfo.processInfo.processIdentifier

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard self != nil else { return }
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            guard app.bundleIdentifier == bundleId, app.processIdentifier != currentPid else { return }
            if let executableURL = app.executableURL?
                   .standardizedFileURL
                   .resolvingSymlinksInPath(),
               executableURL == embeddedCLIURL {
                return
            }

            app.terminate()
            if !app.isTerminated {
                _ = app.forceTerminate()
            }
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        handleNotificationResponse(response)
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        var options: UNNotificationPresentationOptions = [.banner, .list]
        if notification.request.content.sound != nil {
            options.insert(.sound)
        }
        completionHandler(options)
    }

    private func handleNotificationResponse(_ response: UNNotificationResponse) {
        guard let tabIdString = response.notification.request.content.userInfo["tabId"] as? String,
              let tabId = UUID(uuidString: tabIdString) else {
            return
        }
        let surfaceId: UUID? = {
            guard let surfaceIdString = response.notification.request.content.userInfo["surfaceId"] as? String else {
                return nil
            }
            return UUID(uuidString: surfaceIdString)
        }()

        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier, TerminalNotificationStore.actionShowIdentifier:
            let notificationId: UUID? = {
                if let id = UUID(uuidString: response.notification.request.identifier) {
                    return id
                }
                if let idString = response.notification.request.content.userInfo["notificationId"] as? String,
                   let id = UUID(uuidString: idString) {
                    return id
                }
                return nil
            }()
            DispatchQueue.main.async {
                _ = self.openNotification(tabId: tabId, surfaceId: surfaceId, notificationId: notificationId)
            }
        case UNNotificationDismissActionIdentifier:
            DispatchQueue.main.async {
                if let notificationId = UUID(uuidString: response.notification.request.identifier) {
                    self.notificationStore?.markRead(id: notificationId)
                } else if let notificationIdString = response.notification.request.content.userInfo["notificationId"] as? String,
                          let notificationId = UUID(uuidString: notificationIdString) {
                    self.notificationStore?.markRead(id: notificationId)
                }
            }
        default:
            break
        }
    }

    private func installMainWindowKeyObserver() {
        guard windowKeyObserver == nil else { return }
        windowKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, let window = note.object as? NSWindow else { return }
            self.setActiveMainWindow(window)
        }
    }

    private func installBrowserAddressBarFocusObservers() {
        guard browserAddressBarFocusObserver == nil,
              browserAddressBarBlurObserver == nil,
              browserWebViewFirstResponderObserver == nil else { return }

        browserAddressBarFocusObserver = NotificationCenter.default.addObserver(
            forName: .browserDidFocusAddressBar,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let panelId = notification.object as? UUID else { return }
            self.browserPanel(for: panelId)?.beginSuppressWebViewFocusForAddressBar()
            self.browserAddressBarFocusedPanelId = panelId
            self.stopBrowserOmnibarSelectionRepeat()
#if DEBUG
            dlog("addressBar FOCUS panelId=\(panelId.uuidString.prefix(8))")
#endif
        }

        browserAddressBarBlurObserver = NotificationCenter.default.addObserver(
            forName: .browserDidBlurAddressBar,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let panelId = notification.object as? UUID else { return }
            self.browserPanel(for: panelId)?.endSuppressWebViewFocusForAddressBar()
            if self.browserAddressBarFocusedPanelId == panelId {
                self.browserAddressBarFocusedPanelId = nil
                self.stopBrowserOmnibarSelectionRepeat()
#if DEBUG
                dlog("addressBar BLUR panelId=\(panelId.uuidString.prefix(8))")
#endif
            }
        }

        browserWebViewFirstResponderObserver = NotificationCenter.default.addObserver(
            forName: .browserDidBecomeFirstResponderWebView,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let webView = notification.object as? CmuxWebView,
                  let panel = self.browserPanelOwning(webView) else { return }

            if let trackedPanelId = self.browserAddressBarFocusedPanelId,
               trackedPanelId != panel.id,
               let trackedPanel = self.browserPanel(for: trackedPanelId),
               !self.shouldPreserveBrowserAddressBarTracking(for: trackedPanel) {
                trackedPanel.endSuppressWebViewFocusForAddressBar()
                self.browserAddressBarFocusedPanelId = nil
                self.stopBrowserOmnibarSelectionRepeat()
#if DEBUG
                dlog(
                    "addressBar CLEAR panelId=\(trackedPanelId.uuidString.prefix(8)) " +
                    "reason=stale_other_panel_webViewFirstResponder"
                )
#endif
            }

            guard !self.shouldPreserveBrowserAddressBarTracking(for: panel) else {
#if DEBUG
                dlog(
                    "addressBar CLEAR panelId=\(panel.id.uuidString.prefix(8)) " +
                    "reason=skip_preserve_omnibar_handoff"
                )
#endif
                return
            }
            panel.endSuppressWebViewFocusForAddressBar()
            if self.browserAddressBarFocusedPanelId == panel.id {
                self.browserAddressBarFocusedPanelId = nil
                self.stopBrowserOmnibarSelectionRepeat()
#if DEBUG
                dlog(
                    "addressBar CLEAR panelId=\(panel.id.uuidString.prefix(8)) " +
                    "reason=webViewFirstResponder"
                )
#endif
            }
        }
    }

    private func browserPanel(for panelId: UUID) -> BrowserPanel? {
        return workspaceContainingPanel(panelId: panelId)?.workspace.browserPanel(for: panelId)
    }

    fileprivate func browserFindBarIsVisible(for webView: CmuxWebView) -> Bool {
        browserPanelOwning(webView)?.searchState != nil
    }

    private func shouldLetFocusedBrowserOwnFindShortcut(_ event: NSEvent) -> Bool {
        let shortcutWindow = resolvedShortcutEventWindow(event) ?? NSApp.keyWindow ?? NSApp.mainWindow
        let shortcutResponder = shortcutWindow?.firstResponder
        let owningWebView = tabManager?.focusedBrowserPanel?.webView as? CmuxWebView
        guard let owningWebView else { return false }
        return shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst(
            event,
            responder: shortcutResponder,
            owningWebView: owningWebView
        )
    }

    private func browserPanelOwning(_ webView: CmuxWebView) -> BrowserPanel? {
        var candidateManagers: [TabManager] = []
        var seenManagers = Set<ObjectIdentifier>()

        func appendCandidate(_ manager: TabManager?) {
            guard let manager else { return }
            let identifier = ObjectIdentifier(manager)
            guard seenManagers.insert(identifier).inserted else { return }
            candidateManagers.append(manager)
        }

        if let window = webView.window,
           let context = contextForMainWindow(window) {
            appendCandidate(context.tabManager)
        }
        appendCandidate(tabManager)
        for context in mainWindowContexts.values {
            appendCandidate(context.tabManager)
        }

        for manager in candidateManagers {
            if let panel = browserPanelOwning(webView, in: manager) {
                return panel
            }
        }
        return nil
    }

    private func browserPanelOwning(_ webView: CmuxWebView, in manager: TabManager) -> BrowserPanel? {
        for workspace in manager.tabs {
            if let panel = workspace.panels.values
                .compactMap({ $0 as? BrowserPanel })
                .first(where: { $0.webView === webView }) {
                return panel
            }
        }
        return nil
    }

    private func setActiveMainWindow(_ window: NSWindow) {
        guard let context = contextForMainTerminalWindow(window) else { return }
#if DEBUG
        let beforeManagerToken = debugManagerToken(tabManager)
#endif
        tabManager = context.tabManager
        sidebarState = context.sidebarState
        sidebarSelectionState = context.sidebarSelectionState
        TerminalController.shared.setActiveTabManager(context.tabManager)
#if DEBUG
        dlog(
            "mainWindow.active window={\(debugWindowToken(window))} context={\(debugContextToken(context))} beforeMgr=\(beforeManagerToken) afterMgr=\(debugManagerToken(tabManager)) \(debugShortcutRouteSnapshot())"
        )
#endif
    }

    private func unregisterMainWindow(_ window: NSWindow) {
        // Reset cascade point so the next new window appears near the closing
        // window's position, matching upstream Ghostty behavior.
        let frame = window.frame
        lastCascadePoint = NSPoint(x: frame.minX, y: frame.maxY)

        // Keep geometry available as a fallback even if the full session snapshot
        // is removed when the last window closes.
        persistWindowGeometry(from: window)
        guard let removed = unregisterMainWindowContext(for: window) else { return }
        commandPaletteVisibilityByWindowId.removeValue(forKey: removed.windowId)
        commandPalettePendingOpenByWindowId.removeValue(forKey: removed.windowId)
        commandPaletteRecentRequestAtByWindowId.removeValue(forKey: removed.windowId)
        commandPaletteEscapeSuppressionByWindowId.remove(removed.windowId)
        commandPaletteEscapeSuppressionStartedAtByWindowId.removeValue(forKey: removed.windowId)
        commandPaletteSelectionByWindowId.removeValue(forKey: removed.windowId)
        commandPaletteSnapshotByWindowId.removeValue(forKey: removed.windowId)

        // Avoid stale notifications that can no longer be opened once the owning window is gone.
        if let store = notificationStore {
            for tab in removed.tabManager.tabs {
                store.clearNotifications(forTabId: tab.id)
            }
        }

        if tabManager === removed.tabManager {
            // Repoint "active" pointers to any remaining main terminal window.
            let nextContext: MainWindowContext? = {
                if let keyWindow = NSApp.keyWindow,
                   let ctx = contextForMainTerminalWindow(keyWindow, reindex: false) {
                    return ctx
                }
                return mainWindowContexts.values.first
            }()

            if let nextContext {
                tabManager = nextContext.tabManager
                sidebarState = nextContext.sidebarState
                sidebarSelectionState = nextContext.sidebarSelectionState
                TerminalController.shared.setActiveTabManager(nextContext.tabManager)
            } else {
                tabManager = nil
                sidebarState = nil
                sidebarSelectionState = nil
                TerminalController.shared.setActiveTabManager(nil)
            }
        }

        // During app termination we already persisted a full snapshot (with scrollback)
        // in applicationShouldTerminate/applicationWillTerminate. Saving again here would
        // overwrite it as windows tear down one-by-one, dropping closed windows and replay.
        if Self.shouldPersistSnapshotOnWindowUnregister(isTerminatingApp: isTerminatingApp) {
            _ = saveSessionSnapshot(
                includeScrollback: false,
                removeWhenEmpty: Self.shouldRemoveSnapshotWhenNoWindowsRemainOnWindowUnregister(
                    isTerminatingApp: isTerminatingApp
                )
            )
        }
    }

    private func isMainTerminalWindow(_ window: NSWindow) -> Bool {
        if mainWindowContexts[ObjectIdentifier(window)] != nil {
            return true
        }
        guard let raw = window.identifier?.rawValue else { return false }
        return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
    }

    private func contextContainingTabId(_ tabId: UUID) -> MainWindowContext? {
        for context in mainWindowContexts.values {
            if context.tabManager.tabs.contains(where: { $0.id == tabId }) {
                return context
            }
        }
        return nil
    }

    /// Returns the `TabManager` that owns `tabId`, if any.
    func tabManagerFor(tabId: UUID) -> TabManager? {
        contextContainingTabId(tabId)?.tabManager
    }

    private func workspaceForMainActor(tabId: UUID) -> Workspace? {
        contextContainingTabId(tabId)?.tabManager.tabs.first(where: { $0.id == tabId })
    }

    /// Returns the `Workspace` that owns `tabId`, if any.
    @MainActor
    func workspaceFor(tabId: UUID) -> Workspace? {
        workspaceForMainActor(tabId: tabId)
    }

    func closeMainWindowContainingTabId(_ tabId: UUID) {
        guard let context = contextContainingTabId(tabId) else { return }
        let expectedIdentifier = "cmux.main.\(context.windowId.uuidString)"
        let window: NSWindow? = context.window ?? NSApp.windows.first(where: { $0.identifier?.rawValue == expectedIdentifier })
        window?.performClose(nil)
    }

    @discardableResult
    func openNotification(tabId: UUID, surfaceId: UUID?, notificationId: UUID?) -> Bool {
#if DEBUG
        let isJumpUnreadUITest = ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1"
        if isJumpUnreadUITest {
            writeJumpUnreadTestData([
                "jumpUnreadOpenCalled": "1",
                "jumpUnreadOpenTabId": tabId.uuidString,
                "jumpUnreadOpenSurfaceId": surfaceId?.uuidString ?? "",
            ])
        }
#endif
        guard let context = contextContainingTabId(tabId) else {
#if DEBUG
            recordMultiWindowNotificationOpenFailureIfNeeded(
                tabId: tabId,
                surfaceId: surfaceId,
                notificationId: notificationId,
                reason: "missing_context"
            )
#endif
#if DEBUG
            if isJumpUnreadUITest {
                writeJumpUnreadTestData(["jumpUnreadOpenContextFound": "0", "jumpUnreadOpenUsedFallback": "1"])
            }
#endif
            let ok = openNotificationFallback(tabId: tabId, surfaceId: surfaceId, notificationId: notificationId)
#if DEBUG
            if isJumpUnreadUITest {
                writeJumpUnreadTestData(["jumpUnreadOpenResult": ok ? "1" : "0"])
            }
#endif
            return ok
        }
#if DEBUG
        if isJumpUnreadUITest {
            writeJumpUnreadTestData(["jumpUnreadOpenContextFound": "1", "jumpUnreadOpenUsedFallback": "0"])
        }
#endif
        return openNotificationInContext(context, tabId: tabId, surfaceId: surfaceId, notificationId: notificationId)
    }

    private func openNotificationInContext(_ context: MainWindowContext, tabId: UUID, surfaceId: UUID?, notificationId: UUID?) -> Bool {
        let expectedIdentifier = "cmux.main.\(context.windowId.uuidString)"
        let window: NSWindow? = context.window ?? NSApp.windows.first(where: { $0.identifier?.rawValue == expectedIdentifier })
        guard let window else {
#if DEBUG
            recordMultiWindowNotificationOpenFailureIfNeeded(
                tabId: tabId,
                surfaceId: surfaceId,
                notificationId: notificationId,
                reason: "missing_window expectedIdentifier=\(expectedIdentifier)"
            )
#endif
            return false
        }

        context.sidebarSelectionState.selection = .tabs
        bringToFront(window)
        guard context.tabManager.focusTabFromNotification(tabId, surfaceId: surfaceId) else {
#if DEBUG
            recordMultiWindowNotificationOpenFailureIfNeeded(
                tabId: tabId,
                surfaceId: surfaceId,
                notificationId: notificationId,
                reason: "focus_failed"
            )
            if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
                writeJumpUnreadTestData(["jumpUnreadOpenResult": "0"])
            }
#endif
            return false
        }

#if DEBUG
        // UI test support: Jump-to-unread asserts that the correct workspace/panel is focused.
        // Recording via first-responder can be flaky on the VM, so verify focus via the model.
        recordJumpUnreadFocusFromModelIfNeeded(
            tabManager: context.tabManager,
            tabId: tabId,
            expectedSurfaceId: surfaceId
        )
#endif

        if let notificationId, let store = notificationStore {
            markReadIfFocused(
                notificationId: notificationId,
                tabId: tabId,
                surfaceId: surfaceId,
                tabManager: context.tabManager,
                notificationStore: store
            )
        }

#if DEBUG
        recordMultiWindowNotificationFocusIfNeeded(
            windowId: context.windowId,
            tabId: tabId,
            surfaceId: surfaceId,
            sidebarSelection: context.sidebarSelectionState.selection
        )
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
            writeJumpUnreadTestData(["jumpUnreadOpenInContext": "1", "jumpUnreadOpenResult": "1"])
        }
#endif
        return true
    }

    private func openNotificationFallback(tabId: UUID, surfaceId: UUID?, notificationId: UUID?) -> Bool {
        // If the owning window context hasn't been registered yet, fall back to the "active" window.
        guard let tabManager else {
#if DEBUG
            if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
                writeJumpUnreadTestData(["jumpUnreadFallbackFail": "missing_tabManager"])
            }
#endif
            return false
        }
        guard tabManager.tabs.contains(where: { $0.id == tabId }) else {
#if DEBUG
            if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
                writeJumpUnreadTestData(["jumpUnreadFallbackFail": "tab_not_in_active_manager"])
            }
#endif
            return false
        }
        guard let window = (NSApp.keyWindow ?? NSApp.windows.first(where: { isMainTerminalWindow($0) })) else {
#if DEBUG
            if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
                writeJumpUnreadTestData(["jumpUnreadFallbackFail": "missing_window"])
            }
#endif
            return false
        }

        sidebarSelectionState?.selection = .tabs
        bringToFront(window)
        guard tabManager.focusTabFromNotification(tabId, surfaceId: surfaceId) else {
#if DEBUG
            if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
                writeJumpUnreadTestData([
                    "jumpUnreadFallbackFail": "focus_failed",
                    "jumpUnreadOpenResult": "0",
                ])
            }
#endif
            return false
        }

#if DEBUG
        recordJumpUnreadFocusFromModelIfNeeded(
            tabManager: tabManager,
            tabId: tabId,
            expectedSurfaceId: surfaceId
        )
#endif

        if let notificationId, let store = notificationStore {
            markReadIfFocused(
                notificationId: notificationId,
                tabId: tabId,
                surfaceId: surfaceId,
                tabManager: tabManager,
                notificationStore: store
            )
        }
#if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
            writeJumpUnreadTestData(["jumpUnreadOpenInFallback": "1", "jumpUnreadOpenResult": "1"])
        }
#endif
        return true
    }

#if DEBUG
    private func recordJumpUnreadFocusFromModelIfNeeded(
        tabManager: TabManager,
        tabId: UUID,
        expectedSurfaceId: UUID?
    ) {
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" else { return }
        guard let expectedSurfaceId else { return }

        // Ensure the expectation is armed even if the view doesn't become first responder.
        armJumpUnreadFocusRecord(tabId: tabId, surfaceId: expectedSurfaceId)

        if tabManager.selectedTabId == tabId,
           tabManager.focusedSurfaceId(for: tabId) == expectedSurfaceId {
            recordJumpUnreadFocusIfExpected(tabId: tabId, surfaceId: expectedSurfaceId)
            return
        }

        var resolved = false
        var observers: [NSObjectProtocol] = []
        var cancellables: [AnyCancellable] = []

        func cleanup() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            cancellables.forEach { $0.cancel() }
            cancellables.removeAll()
        }

        @MainActor
        func finishIfFocused() {
            guard !resolved else { return }
            guard tabManager.selectedTabId == tabId,
                  tabManager.focusedSurfaceId(for: tabId) == expectedSurfaceId else {
                return
            }
            resolved = true
            cleanup()
            self.recordJumpUnreadFocusIfExpected(tabId: tabId, surfaceId: expectedSurfaceId)
        }

        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusSurface,
            object: nil,
            queue: .main
        ) { note in
            guard let surfaceId = note.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID,
                  surfaceId == expectedSurfaceId else { return }
            Task { @MainActor in finishIfFocused() }
        })
        cancellables.append(tabManager.$selectedTabId.sink { _ in
            Task { @MainActor in finishIfFocused() }
        })
        if let workspace = tabManager.tabs.first(where: { $0.id == tabId }) {
            cancellables.append(workspace.$panels
                .map { _ in () }
                .sink { _ in
                    Task { @MainActor in finishIfFocused() }
                })
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            Task { @MainActor in
                guard !resolved else { return }
                cleanup()
            }
        }
        Task { @MainActor in finishIfFocused() }
    }
#endif

    func tabTitle(for tabId: UUID) -> String? {
        if let context = contextContainingTabId(tabId) {
            return context.tabManager.tabs.first(where: { $0.id == tabId })?.title
        }
        return tabManager?.tabs.first(where: { $0.id == tabId })?.title
    }

    private func bringToFront(_ window: NSWindow) {
        if TerminalController.shouldSuppressSocketCommandActivation(),
           !TerminalController.socketCommandAllowsInAppFocusMutations() {
            return
        }
        setActiveMainWindow(window)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        // Improve reliability across Spaces / when other helper panels are key.
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    private func markReadIfFocused(
        notificationId: UUID,
        tabId: UUID,
        surfaceId: UUID?,
        tabManager: TabManager,
        notificationStore: TerminalNotificationStore
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard tabManager.selectedTabId == tabId else { return }
            if let surfaceId {
                guard tabManager.focusedSurfaceId(for: tabId) == surfaceId else { return }
            }
            notificationStore.markRead(id: notificationId)
        }
    }

#if DEBUG
    private func recordMultiWindowNotificationOpenFailureIfNeeded(
        tabId: UUID,
        surfaceId: UUID?,
        notificationId: UUID?,
        reason: String
    ) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_PATH"], !path.isEmpty else { return }

        let contextSummaries: [String] = mainWindowContexts.values.map { ctx in
            let tabIds = ctx.tabManager.tabs.map { $0.id.uuidString }.joined(separator: ",")
            let hasWindow = (ctx.window != nil) ? "1" : "0"
            return "windowId=\(ctx.windowId.uuidString) hasWindow=\(hasWindow) tabs=[\(tabIds)]"
        }

        writeMultiWindowNotificationTestData([
            "focusToken": UUID().uuidString,
            "openFailureTabId": tabId.uuidString,
            "openFailureSurfaceId": surfaceId?.uuidString ?? "",
            "openFailureNotificationId": notificationId?.uuidString ?? "",
            "openFailureReason": reason,
            "openFailureContexts": contextSummaries.joined(separator: "; "),
        ], at: path)
    }
#endif

}

@MainActor
final class MenuBarExtraController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu(title: "cmux")
    private let notificationStore: TerminalNotificationStore
    private let onShowNotifications: () -> Void
    private let onOpenNotification: (TerminalNotification) -> Void
    private let onJumpToLatestUnread: () -> Void
    private let onCheckForUpdates: () -> Void
    private let onOpenPreferences: () -> Void
    private let onQuitApp: () -> Void
    private var notificationsCancellable: AnyCancellable?
    private let buildHintTitle: String?

    private let stateHintItem = NSMenuItem(title: String(localized: "statusMenu.noUnread", defaultValue: "No unread notifications"), action: nil, keyEquivalent: "")
    private let buildHintItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let notificationListSeparator = NSMenuItem.separator()
    private let notificationSectionSeparator = NSMenuItem.separator()
    private let showNotificationsItem = NSMenuItem(title: String(localized: "statusMenu.showNotifications", defaultValue: "Show Notifications"), action: nil, keyEquivalent: "")
    private let jumpToUnreadItem = NSMenuItem(title: String(localized: "statusMenu.jumpToLatestUnread", defaultValue: "Jump to Latest Unread"), action: nil, keyEquivalent: "")
    private let markAllReadItem = NSMenuItem(title: String(localized: "statusMenu.markAllRead", defaultValue: "Mark All Read"), action: nil, keyEquivalent: "")
    private let clearAllItem = NSMenuItem(title: String(localized: "statusMenu.clearAll", defaultValue: "Clear All"), action: nil, keyEquivalent: "")
    private let checkForUpdatesItem = NSMenuItem(title: String(localized: "menu.checkForUpdates", defaultValue: "Check for Updates…"), action: nil, keyEquivalent: "")
    private let preferencesItem = NSMenuItem(title: String(localized: "menu.preferences", defaultValue: "Preferences…"), action: nil, keyEquivalent: "")
    private let quitItem = NSMenuItem(title: String(localized: "menu.quitCmux", defaultValue: "Quit cmux"), action: nil, keyEquivalent: "")

    private var notificationItems: [NSMenuItem] = []
    private let maxInlineNotificationItems = 6

    init(
        notificationStore: TerminalNotificationStore,
        onShowNotifications: @escaping () -> Void,
        onOpenNotification: @escaping (TerminalNotification) -> Void,
        onJumpToLatestUnread: @escaping () -> Void,
        onCheckForUpdates: @escaping () -> Void,
        onOpenPreferences: @escaping () -> Void,
        onQuitApp: @escaping () -> Void
    ) {
        self.notificationStore = notificationStore
        self.onShowNotifications = onShowNotifications
        self.onOpenNotification = onOpenNotification
        self.onJumpToLatestUnread = onJumpToLatestUnread
        self.onCheckForUpdates = onCheckForUpdates
        self.onOpenPreferences = onOpenPreferences
        self.onQuitApp = onQuitApp
        self.buildHintTitle = MenuBarBuildHintFormatter.menuTitle()
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        buildMenu()
        statusItem.menu = menu
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.image = MenuBarIconRenderer.makeImage(unreadCount: 0)
            button.toolTip = "cmux"
        }

        notificationsCancellable = notificationStore.$notifications
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshUI()
            }

        refreshUI()
    }

    private func buildMenu() {
        menu.autoenablesItems = false
        menu.delegate = self

        stateHintItem.isEnabled = false
        menu.addItem(stateHintItem)
        if let buildHintTitle {
            buildHintItem.title = buildHintTitle
            buildHintItem.isEnabled = false
            menu.addItem(buildHintItem)
        }

        menu.addItem(notificationListSeparator)
        notificationSectionSeparator.isHidden = true
        menu.addItem(notificationSectionSeparator)

        showNotificationsItem.target = self
        showNotificationsItem.action = #selector(showNotificationsAction)
        menu.addItem(showNotificationsItem)

        jumpToUnreadItem.target = self
        jumpToUnreadItem.action = #selector(jumpToUnreadAction)
        menu.addItem(jumpToUnreadItem)

        markAllReadItem.target = self
        markAllReadItem.action = #selector(markAllReadAction)
        menu.addItem(markAllReadItem)

        clearAllItem.target = self
        clearAllItem.action = #selector(clearAllAction)
        menu.addItem(clearAllItem)

        menu.addItem(.separator())

        checkForUpdatesItem.target = self
        checkForUpdatesItem.action = #selector(checkForUpdatesAction)
        menu.addItem(checkForUpdatesItem)

        preferencesItem.target = self
        preferencesItem.action = #selector(preferencesAction)
        menu.addItem(preferencesItem)

        menu.addItem(.separator())

        quitItem.target = self
        quitItem.action = #selector(quitAction)
        menu.addItem(quitItem)
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshUI()
    }

    func refreshForDebugControls() {
        refreshUI()
    }

    func removeFromMenuBar() {
        notificationsCancellable?.cancel()
        notificationsCancellable = nil
        statusItem.menu = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func refreshUI() {
        let snapshot = NotificationMenuSnapshotBuilder.make(
            notifications: notificationStore.notifications,
            maxInlineNotificationItems: maxInlineNotificationItems
        )
        let actualUnreadCount = snapshot.unreadCount

        let displayedUnreadCount: Int
#if DEBUG
        displayedUnreadCount = MenuBarIconDebugSettings.displayedUnreadCount(actualUnreadCount: actualUnreadCount)
#else
        displayedUnreadCount = actualUnreadCount
#endif

        stateHintItem.title = snapshot.stateHintTitle

        applyShortcut(KeyboardShortcutSettings.shortcut(for: .showNotifications), to: showNotificationsItem)
        applyShortcut(KeyboardShortcutSettings.shortcut(for: .jumpToUnread), to: jumpToUnreadItem)

        jumpToUnreadItem.isEnabled = snapshot.hasUnreadNotifications
        markAllReadItem.isEnabled = snapshot.hasUnreadNotifications
        clearAllItem.isEnabled = snapshot.hasNotifications

        rebuildInlineNotificationItems(recentNotifications: snapshot.recentNotifications)

        if let button = statusItem.button {
            button.image = MenuBarIconRenderer.makeImage(unreadCount: displayedUnreadCount)
            button.toolTip = displayedUnreadCount == 0
                ? "cmux"
                : displayedUnreadCount == 1
                    ? "cmux: " + String(localized: "statusMenu.tooltip.unread.one", defaultValue: "1 unread notification")
                    : "cmux: " + String(localized: "statusMenu.tooltip.unread.other", defaultValue: "\(displayedUnreadCount) unread notifications")
        }
    }

    private func applyShortcut(_ shortcut: StoredShortcut, to item: NSMenuItem) {
        guard let keyEquivalent = shortcut.menuItemKeyEquivalent else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }
        item.keyEquivalent = keyEquivalent
        item.keyEquivalentModifierMask = shortcut.modifierFlags
    }

    private func rebuildInlineNotificationItems(recentNotifications: [TerminalNotification]) {
        for item in notificationItems {
            menu.removeItem(item)
        }
        notificationItems.removeAll(keepingCapacity: true)

        notificationListSeparator.isHidden = recentNotifications.isEmpty
        notificationSectionSeparator.isHidden = recentNotifications.isEmpty
        guard !recentNotifications.isEmpty else { return }

        let insertionIndex = menu.index(of: showNotificationsItem)
        guard insertionIndex >= 0 else { return }

        for (offset, notification) in recentNotifications.enumerated() {
            let tabTitle = AppDelegate.shared?.tabTitle(for: notification.tabId)
            let item = makeNotificationItem(notification: notification, tabTitle: tabTitle)
            menu.insertItem(item, at: insertionIndex + offset)
            notificationItems.append(item)
        }
    }

    private func makeNotificationItem(notification: TerminalNotification, tabTitle: String?) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: #selector(openNotificationItemAction(_:)), keyEquivalent: "")
        item.target = self
        item.attributedTitle = MenuBarNotificationLineFormatter.attributedTitle(notification: notification, tabTitle: tabTitle)
        item.toolTip = MenuBarNotificationLineFormatter.tooltip(notification: notification, tabTitle: tabTitle)
        item.representedObject = NotificationMenuItemPayload(notification: notification)
        return item
    }

    @objc private func openNotificationItemAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? NotificationMenuItemPayload else { return }
        onOpenNotification(payload.notification)
    }

    @objc private func showNotificationsAction() {
        onShowNotifications()
    }

    @objc private func jumpToUnreadAction() {
        onJumpToLatestUnread()
    }

    @objc private func markAllReadAction() {
        notificationStore.markAllRead()
    }

    @objc private func clearAllAction() {
        notificationStore.clearAll()
    }

    @objc private func checkForUpdatesAction() {
        onCheckForUpdates()
    }

    @objc private func preferencesAction() {
        onOpenPreferences()
    }

    @objc private func quitAction() {
        onQuitApp()
    }
}

private final class NotificationMenuItemPayload: NSObject {
    let notification: TerminalNotification

    init(notification: TerminalNotification) {
        self.notification = notification
        super.init()
    }
}

struct NotificationMenuSnapshot {
    let unreadCount: Int
    let hasNotifications: Bool
    let recentNotifications: [TerminalNotification]

    var hasUnreadNotifications: Bool {
        unreadCount > 0
    }

    var stateHintTitle: String {
        NotificationMenuSnapshotBuilder.stateHintTitle(unreadCount: unreadCount)
    }
}

enum NotificationMenuSnapshotBuilder {
    static let defaultInlineNotificationLimit = 6

    static func make(
        notifications: [TerminalNotification],
        maxInlineNotificationItems: Int = defaultInlineNotificationLimit
    ) -> NotificationMenuSnapshot {
        let unreadCount = notifications.reduce(into: 0) { count, notification in
            if !notification.isRead {
                count += 1
            }
        }

        let inlineLimit = max(0, maxInlineNotificationItems)
        return NotificationMenuSnapshot(
            unreadCount: unreadCount,
            hasNotifications: !notifications.isEmpty,
            recentNotifications: Array(notifications.prefix(inlineLimit))
        )
    }

    static func stateHintTitle(unreadCount: Int) -> String {
        switch unreadCount {
        case 0:
            return String(localized: "statusMenu.noUnread", defaultValue: "No unread notifications")
        case 1:
            return String(localized: "statusMenu.unreadCount.one", defaultValue: "1 unread notification")
        default:
            return String(localized: "statusMenu.unreadCount.other", defaultValue: "\(unreadCount) unread notifications")
        }
    }
}

enum MenuBarBadgeLabelFormatter {
    static func badgeText(for unreadCount: Int) -> String? {
        guard unreadCount > 0 else { return nil }
        if unreadCount > 9 {
            return "9+"
        }
        return String(unreadCount)
    }
}

enum MenuBarNotificationLineFormatter {
    static let defaultMaxMenuTextWidth: CGFloat = 280
    static let defaultMaxMenuTextLines = 3

    static func plainTitle(notification: TerminalNotification, tabTitle: String?) -> String {
        let dot = notification.isRead ? "  " : "● "
        let timeText = notification.createdAt.formatted(date: .omitted, time: .shortened)
        var lines: [String] = []
        lines.append("\(dot)\(notification.title)  \(timeText)")

        let detail = notification.body.isEmpty ? notification.subtitle : notification.body
        if !detail.isEmpty {
            lines.append(detail)
        }

        if let tabTitle, !tabTitle.isEmpty {
            lines.append(tabTitle)
        }

        return lines.joined(separator: "\n")
    }

    static func menuTitle(
        notification: TerminalNotification,
        tabTitle: String?,
        maxWidth: CGFloat = defaultMaxMenuTextWidth,
        maxLines: Int = defaultMaxMenuTextLines
    ) -> String {
        let base = plainTitle(notification: notification, tabTitle: tabTitle)
        return wrappedAndTruncated(base, maxWidth: maxWidth, maxLines: maxLines)
    }

    static func attributedTitle(notification: TerminalNotification, tabTitle: String?) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(
            string: menuTitle(notification: notification, tabTitle: tabTitle),
            attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
        )
    }

    static func tooltip(notification: TerminalNotification, tabTitle: String?) -> String {
        plainTitle(notification: notification, tabTitle: tabTitle)
    }

    private static func wrappedAndTruncated(_ text: String, maxWidth: CGFloat, maxLines: Int) -> String {
        let width = max(60, maxWidth)
        let lines = max(1, maxLines)
        let font = NSFont.menuFont(ofSize: NSFont.systemFontSize)
        let wrapped = wrappedLines(for: text, maxWidth: width, font: font)
        guard wrapped.count > lines else { return wrapped.joined(separator: "\n") }

        var clipped = Array(wrapped.prefix(lines))
        clipped[lines - 1] = truncateLine(clipped[lines - 1], maxWidth: width, font: font)
        return clipped.joined(separator: "\n")
    }

    private static func wrappedLines(for text: String, maxWidth: CGFloat, font: NSFont) -> [String] {
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: maxWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byWordWrapping
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        _ = layout.glyphRange(for: container)

        let fullText = text as NSString
        var rows: [String] = []
        var glyphIndex = 0
        while glyphIndex < layout.numberOfGlyphs {
            var glyphRange = NSRange()
            layout.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &glyphRange)
            if glyphRange.length == 0 { break }

            let charRange = layout.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            let row = fullText.substring(with: charRange).trimmingCharacters(in: .newlines)
            rows.append(row)
            glyphIndex = NSMaxRange(glyphRange)
        }

        if rows.isEmpty {
            return [text]
        }
        return rows
    }

    private static func truncateLine(_ line: String, maxWidth: CGFloat, font: NSFont) -> String {
        let ellipsis = "…"
        let full = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if full.isEmpty { return ellipsis }

        if measuredWidth(full + ellipsis, font: font) <= maxWidth {
            return full + ellipsis
        }

        var chars = Array(full)
        while !chars.isEmpty {
            chars.removeLast()
            let candidateBase = String(chars).trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = (candidateBase.isEmpty ? "" : candidateBase) + ellipsis
            if measuredWidth(candidate, font: font) <= maxWidth {
                return candidate
            }
        }
        return ellipsis
    }

    private static func measuredWidth(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
}

enum MenuBarBuildHintFormatter {
    static func menuTitle(
        appName: String = defaultAppName(),
        isDebugBuild: Bool = _isDebugAssertConfiguration()
    ) -> String? {
        guard isDebugBuild else { return nil }
        let normalized = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "cmux DEV"
        guard normalized.hasPrefix(prefix) else { return "Build: DEV" }

        let suffix = String(normalized.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        if suffix.isEmpty {
            return "Build: DEV (untagged)"
        }
        return "Build Tag: \(suffix)"
    }

    private static func defaultAppName() -> String {
        let bundle = Bundle.main
        if let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !displayName.isEmpty {
            return displayName
        }
        if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String, !name.isEmpty {
            return name
        }
        return ProcessInfo.processInfo.processName
    }
}

enum MenuBarExtraSettings {
    static let showInMenuBarKey = "showMenuBarExtra"
    static let defaultShowInMenuBar = true

    static func showsMenuBarExtra(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: showInMenuBarKey) == nil {
            return defaultShowInMenuBar
        }
        return defaults.bool(forKey: showInMenuBarKey)
    }
}

struct MenuBarBadgeRenderConfig {
    var badgeRect: NSRect
    var singleDigitFontSize: CGFloat
    var multiDigitFontSize: CGFloat
    var singleDigitYOffset: CGFloat
    var multiDigitYOffset: CGFloat
    var singleDigitXAdjust: CGFloat
    var multiDigitXAdjust: CGFloat
    var textRectWidthAdjust: CGFloat
}

enum MenuBarIconDebugSettings {
    static let previewEnabledKey = "menubarDebugPreviewEnabled"
    static let previewCountKey = "menubarDebugPreviewCount"
    static let badgeRectXKey = "menubarDebugBadgeRectX"
    static let badgeRectYKey = "menubarDebugBadgeRectY"
    static let badgeRectWidthKey = "menubarDebugBadgeRectWidth"
    static let badgeRectHeightKey = "menubarDebugBadgeRectHeight"
    static let singleDigitFontSizeKey = "menubarDebugSingleDigitFontSize"
    static let multiDigitFontSizeKey = "menubarDebugMultiDigitFontSize"
    static let singleDigitYOffsetKey = "menubarDebugSingleDigitYOffset"
    static let multiDigitYOffsetKey = "menubarDebugMultiDigitYOffset"
    static let singleDigitXAdjustKey = "menubarDebugSingleDigitXAdjust"
    static let legacySingleDigitXAdjustKey = "menubarDebugTextRectXAdjust"
    static let multiDigitXAdjustKey = "menubarDebugMultiDigitXAdjust"
    static let textRectWidthAdjustKey = "menubarDebugTextRectWidthAdjust"

    static let defaultBadgeRect = NSRect(x: 5.38, y: 6.43, width: 10.75, height: 11.58)
    static let defaultSingleDigitFontSize: CGFloat = 6.7
    static let defaultMultiDigitFontSize: CGFloat = 6.7
    static let defaultSingleDigitYOffset: CGFloat = 0.6
    static let defaultMultiDigitYOffset: CGFloat = 0.6
    static let defaultSingleDigitXAdjust: CGFloat = -1.1
    static let defaultMultiDigitXAdjust: CGFloat = 2.42
    static let defaultTextRectWidthAdjust: CGFloat = 1.8

    static func displayedUnreadCount(actualUnreadCount: Int, defaults: UserDefaults = .standard) -> Int {
        guard defaults.bool(forKey: previewEnabledKey) else { return actualUnreadCount }
        let value = defaults.integer(forKey: previewCountKey)
        return max(0, min(value, 99))
    }

    static func badgeRenderConfig(defaults: UserDefaults = .standard) -> MenuBarBadgeRenderConfig {
        let x = value(defaults, key: badgeRectXKey, fallback: defaultBadgeRect.origin.x, range: 0...20)
        let y = value(defaults, key: badgeRectYKey, fallback: defaultBadgeRect.origin.y, range: 0...20)
        let width = value(defaults, key: badgeRectWidthKey, fallback: defaultBadgeRect.width, range: 4...14)
        let height = value(defaults, key: badgeRectHeightKey, fallback: defaultBadgeRect.height, range: 4...14)
        let singleFont = value(defaults, key: singleDigitFontSizeKey, fallback: defaultSingleDigitFontSize, range: 6...14)
        let multiFont = value(defaults, key: multiDigitFontSizeKey, fallback: defaultMultiDigitFontSize, range: 6...14)
        let singleY = value(defaults, key: singleDigitYOffsetKey, fallback: defaultSingleDigitYOffset, range: -3...4)
        let multiY = value(defaults, key: multiDigitYOffsetKey, fallback: defaultMultiDigitYOffset, range: -3...4)
        let singleX = value(
            defaults,
            key: singleDigitXAdjustKey,
            legacyKey: legacySingleDigitXAdjustKey,
            fallback: defaultSingleDigitXAdjust,
            range: -4...4
        )
        let multiX = value(defaults, key: multiDigitXAdjustKey, fallback: defaultMultiDigitXAdjust, range: -4...4)
        let widthAdjust = value(defaults, key: textRectWidthAdjustKey, fallback: defaultTextRectWidthAdjust, range: -3...5)

        return MenuBarBadgeRenderConfig(
            badgeRect: NSRect(x: x, y: y, width: width, height: height),
            singleDigitFontSize: singleFont,
            multiDigitFontSize: multiFont,
            singleDigitYOffset: singleY,
            multiDigitYOffset: multiY,
            singleDigitXAdjust: singleX,
            multiDigitXAdjust: multiX,
            textRectWidthAdjust: widthAdjust
        )
    }

    static func copyPayload(defaults: UserDefaults = .standard) -> String {
        let config = badgeRenderConfig(defaults: defaults)
        let previewEnabled = defaults.bool(forKey: previewEnabledKey)
        let previewCount = max(0, min(defaults.integer(forKey: previewCountKey), 99))
        return """
        menubarDebugPreviewEnabled=\(previewEnabled)
        menubarDebugPreviewCount=\(previewCount)
        menubarDebugBadgeRectX=\(String(format: "%.2f", config.badgeRect.origin.x))
        menubarDebugBadgeRectY=\(String(format: "%.2f", config.badgeRect.origin.y))
        menubarDebugBadgeRectWidth=\(String(format: "%.2f", config.badgeRect.width))
        menubarDebugBadgeRectHeight=\(String(format: "%.2f", config.badgeRect.height))
        menubarDebugSingleDigitFontSize=\(String(format: "%.2f", config.singleDigitFontSize))
        menubarDebugMultiDigitFontSize=\(String(format: "%.2f", config.multiDigitFontSize))
        menubarDebugSingleDigitYOffset=\(String(format: "%.2f", config.singleDigitYOffset))
        menubarDebugMultiDigitYOffset=\(String(format: "%.2f", config.multiDigitYOffset))
        menubarDebugSingleDigitXAdjust=\(String(format: "%.2f", config.singleDigitXAdjust))
        menubarDebugMultiDigitXAdjust=\(String(format: "%.2f", config.multiDigitXAdjust))
        menubarDebugTextRectWidthAdjust=\(String(format: "%.2f", config.textRectWidthAdjust))
        """
    }

    private static func value(
        _ defaults: UserDefaults,
        key: String,
        legacyKey: String? = nil,
        fallback: CGFloat,
        range: ClosedRange<CGFloat>
    ) -> CGFloat {
        if let parsed = parse(defaults.object(forKey: key), fallback: fallback, range: range) {
            return parsed
        }
        if let legacyKey, let parsed = parse(defaults.object(forKey: legacyKey), fallback: fallback, range: range) {
            return parsed
        }
        return fallback
    }

    private static func parse(
        _ object: Any?,
        fallback: CGFloat,
        range: ClosedRange<CGFloat>
    ) -> CGFloat? {
        guard let number = object as? NSNumber else {
            return nil
        }
        let candidate = CGFloat(number.doubleValue)
        guard candidate.isFinite else { return fallback }
        return max(range.lowerBound, min(candidate, range.upperBound))
    }
}

enum MenuBarIconRenderer {

    static func makeImage(unreadCount: Int) -> NSImage {
        let badgeText = MenuBarBadgeLabelFormatter.badgeText(for: unreadCount)
        let config = MenuBarIconDebugSettings.badgeRenderConfig()
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let glyphRect = NSRect(x: 1.2, y: 1.5, width: 11.6, height: 15.0)
        drawGlyph(in: glyphRect)

        if let text = badgeText {
            drawBadge(text: text, in: config.badgeRect, config: config)
        }

        image.isTemplate = true
        return image
    }

    private static func drawGlyph(in rect: NSRect) {
        // Match the canonical cmux center-mark path from Icon Center Image Artwork.svg.
        let srcMinX: CGFloat = 384.0
        let srcMinY: CGFloat = 255.0
        let srcWidth: CGFloat = 369.0
        let srcHeight: CGFloat = 513.0

        func map(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            let nx = (x - srcMinX) / srcWidth
            let ny = (y - srcMinY) / srcHeight
            return NSPoint(
                x: rect.minX + nx * rect.width,
                y: rect.minY + (1.0 - ny) * rect.height
            )
        }

        let path = NSBezierPath()
        path.move(to: map(384.0, 255.0))
        path.line(to: map(753.0, 511.5))
        path.line(to: map(384.0, 768.0))
        path.line(to: map(384.0, 654.0))
        path.line(to: map(582.692, 511.5))
        path.line(to: map(384.0, 369.0))
        path.close()

        NSColor.black.setFill()
        path.fill()
    }

    private static func drawBadge(text: String, in rect: NSRect, config: MenuBarBadgeRenderConfig) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let fontSize: CGFloat = text.count > 1 ? config.multiDigitFontSize : config.singleDigitFontSize
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.systemBlue,
            .paragraphStyle: paragraph,
        ]
        let yOffset: CGFloat = text.count > 1 ? config.multiDigitYOffset : config.singleDigitYOffset
        let xAdjust: CGFloat = text.count > 1 ? config.multiDigitXAdjust : config.singleDigitXAdjust
        let textRect = NSRect(
            x: rect.origin.x + xAdjust,
            y: rect.origin.y + yOffset,
            width: rect.width + config.textRectWidthAdjust,
            height: rect.height
        )
        (text as NSString).draw(in: textRect, withAttributes: attrs)
    }
}


#if DEBUG
private var cmuxFirstResponderGuardCurrentEventOverride: NSEvent?
private var cmuxFirstResponderGuardHitViewOverride: NSView?
#endif
private var cmuxFirstResponderGuardCurrentEventContext: NSEvent?
private var cmuxFirstResponderGuardHitViewContext: NSView?
private var cmuxFirstResponderGuardContextWindowNumber: Int?
private var cmuxBrowserReturnForwardingDepth = 0
private var cmuxBrowserArrowForwardingDepth = 0
private var cmuxWindowFirstResponderBypassDepth = 0
private var cmuxFieldEditorOwningWebViewAssociationKey: UInt8 = 0

@discardableResult
func cmuxWithWindowFirstResponderBypass<T>(_ body: () -> T) -> T {
    cmuxWindowFirstResponderBypassDepth += 1
    defer {
        cmuxWindowFirstResponderBypassDepth = max(0, cmuxWindowFirstResponderBypassDepth - 1)
    }
    return body()
}

func cmuxIsWindowFirstResponderBypassActive() -> Bool {
    cmuxWindowFirstResponderBypassDepth > 0
}

private final class CmuxFieldEditorOwningWebViewBox: NSObject {
    weak var webView: CmuxWebView?

    init(webView: CmuxWebView?) {
        self.webView = webView
    }
}

private extension NSApplication {
    @objc func cmux_applicationSendEvent(_ event: NSEvent) {
#if DEBUG
        let typingTimingStart = event.type == .keyDown ? CmuxTypingTiming.start() : nil
        let phaseTotalStart = event.type == .keyDown ? ProcessInfo.processInfo.systemUptime : 0
        if event.type == .keyDown {
            CmuxTypingTiming.logEventDelay(path: "app.sendEvent", event: event)
        }
        defer {
            if event.type == .keyDown {
                let totalMs = (ProcessInfo.processInfo.systemUptime - phaseTotalStart) * 1000.0
                CmuxTypingTiming.logBreakdown(
                    path: "app.sendEvent.phase",
                    totalMs: totalMs,
                    event: event,
                    thresholdMs: 1.0,
                    parts: [("dispatchMs", totalMs)]
                )
                CmuxTypingTiming.logDuration(
                    path: "app.sendEvent",
                    startedAt: typingTimingStart,
                    event: event
                )
            }
        }
#endif
        cmux_applicationSendEvent(event)
    }
}

private extension AppDelegate {
    @objc func handleThemesReloadNotification(_ notification: Notification) {
        DispatchQueue.main.async {
            GhosttyApp.shared.reloadConfiguration(source: "distributed.cmux.themes")
        }
    }
}

private extension NSWindow {
    @objc func cmux_makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if cmuxIsWindowFirstResponderBypassActive() {
#if DEBUG
            dlog(
                "focus.guard bypassFirstResponder responder=\(String(describing: responder.map { type(of: $0) })) " +
                "window=\(ObjectIdentifier(self))"
            )
#endif
            return false
        }

        let currentEvent = Self.cmuxCurrentEvent(for: self)
        let responderWebView = responder.flatMap {
            Self.cmuxOwningWebView(for: $0, in: self, event: currentEvent)
        }
        var pointerInitiatedWebFocus = false

        if AppDelegate.shared?.shouldBlockFirstResponderChangeWhileCommandPaletteVisible(
            window: self,
            responder: responder
        ) == true {
#if DEBUG
            dlog(
                "focus.guard commandPaletteBlocked responder=\(String(describing: responder.map { type(of: $0) })) " +
                "window=\(ObjectIdentifier(self))"
            )
#endif
            return false
        }

        if let responder,
           let webView = responderWebView,
           !webView.allowsFirstResponderAcquisitionEffective {
            let pointerInitiatedFocus = Self.cmuxShouldAllowPointerInitiatedWebViewFocus(
                window: self,
                webView: webView,
                event: currentEvent
            )
            if pointerInitiatedFocus {
                pointerInitiatedWebFocus = true
#if DEBUG
                dlog(
                    "focus.guard allowPointerFirstResponder responder=\(String(describing: type(of: responder))) " +
                    "window=\(ObjectIdentifier(self)) " +
                    "web=\(ObjectIdentifier(webView)) " +
                    "policy=\(webView.allowsFirstResponderAcquisition ? 1 : 0) " +
                    "pointerDepth=\(webView.debugPointerFocusAllowanceDepth) " +
                    "eventType=\(currentEvent.map { String(describing: $0.type) } ?? "nil")"
                )
#endif
            } else {
#if DEBUG
                dlog(
                    "focus.guard blockedFirstResponder responder=\(String(describing: type(of: responder))) " +
                    "window=\(ObjectIdentifier(self)) " +
                    "web=\(ObjectIdentifier(webView)) " +
                    "policy=\(webView.allowsFirstResponderAcquisition ? 1 : 0) " +
                    "pointerDepth=\(webView.debugPointerFocusAllowanceDepth) " +
                    "eventType=\(currentEvent.map { String(describing: $0.type) } ?? "nil")"
                )
#endif
                return false
            }
        }
#if DEBUG
        if let responder,
           let webView = responderWebView {
            dlog(
                "focus.guard allowFirstResponder responder=\(String(describing: type(of: responder))) " +
                "window=\(ObjectIdentifier(self)) " +
                "web=\(ObjectIdentifier(webView)) " +
                "policy=\(webView.allowsFirstResponderAcquisition ? 1 : 0) " +
                "pointerDepth=\(webView.debugPointerFocusAllowanceDepth)"
            )
        }
#endif
        let result: Bool
        if pointerInitiatedWebFocus, let webView = responderWebView {
            // `NSWindow.makeFirstResponder` may run before `CmuxWebView.mouseDown(with:)`.
            // Preserve pointer intent during this synchronous responder change.
            result = webView.withPointerFocusAllowance {
                cmux_makeFirstResponder(responder)
            }
        } else {
            result = cmux_makeFirstResponder(responder)
        }
        if result {
            if let fieldEditor = responder as? NSTextView, fieldEditor.isFieldEditor {
                Self.cmuxTrackFieldEditor(fieldEditor, owningWebView: responderWebView)
            } else if let fieldEditor = self.firstResponder as? NSTextView, fieldEditor.isFieldEditor {
                Self.cmuxTrackFieldEditor(fieldEditor, owningWebView: responderWebView)
            }
        }
        return result
    }

    @objc func cmux_sendEvent(_ event: NSEvent) {
#if DEBUG
        let typingTimingStart = event.type == .keyDown ? CmuxTypingTiming.start() : nil
        let phaseTotalStart = event.type == .keyDown ? ProcessInfo.processInfo.systemUptime : 0
        var contextSetupMs: Double = 0
        var focusRepairMs: Double = 0
        var folderGuardMs: Double = 0
        var originalDispatchMs: Double = 0
        let typingTimingExtra: String? = {
            guard event.type == .keyDown else { return nil }
            let responderWebView = self.firstResponder.flatMap {
                Self.cmuxOwningWebView(for: $0, in: self, event: event)
            }
            let hitWebView = Self.cmuxHitViewForEventDispatch(in: self, event: event).flatMap {
                Self.cmuxOwningWebView(for: $0)
            }
            let firstResponderType = self.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            return "browser=\((responderWebView != nil || hitWebView != nil) ? 1 : 0) firstResponder=\(firstResponderType)"
        }()
        if event.type == .keyDown {
            CmuxTypingTiming.logEventDelay(path: "window.sendEvent", event: event)
        }
#endif
        // recordTypingActivity must run in all builds so runSessionAutosaveTick
        // can honor the typing quiet period in release.
        if event.type == .keyDown {
            AppDelegate.shared?.recordTypingActivity()
        }
#if DEBUG
        defer {
            if event.type == .keyDown {
                let totalMs = (ProcessInfo.processInfo.systemUptime - phaseTotalStart) * 1000.0
                CmuxTypingTiming.logBreakdown(
                    path: "window.sendEvent.phase",
                    totalMs: totalMs,
                    event: event,
                    thresholdMs: 1.0,
                    parts: [
                        ("contextSetupMs", contextSetupMs),
                        ("focusRepairMs", focusRepairMs),
                        ("folderGuardMs", folderGuardMs),
                        ("originalDispatchMs", originalDispatchMs),
                    ],
                    extra: typingTimingExtra
                )
                CmuxTypingTiming.logDuration(
                    path: "window.sendEvent",
                    startedAt: typingTimingStart,
                    event: event,
                    extra: typingTimingExtra
                )
            }
        }
        let contextSetupStart = event.type == .keyDown ? ProcessInfo.processInfo.systemUptime : 0
#endif
        let previousContextEvent = cmuxFirstResponderGuardCurrentEventContext
        let previousContextHitView = cmuxFirstResponderGuardHitViewContext
        let previousContextWindowNumber = cmuxFirstResponderGuardContextWindowNumber
        cmuxFirstResponderGuardCurrentEventContext = event
        cmuxFirstResponderGuardHitViewContext = Self.cmuxHitViewForEventDispatch(in: self, event: event)
        cmuxFirstResponderGuardContextWindowNumber = self.windowNumber
#if DEBUG
        if event.type == .keyDown {
            contextSetupMs = (ProcessInfo.processInfo.systemUptime - contextSetupStart) * 1000.0
        }
        let focusRepairStart = event.type == .keyDown ? ProcessInfo.processInfo.systemUptime : 0
#endif
        if event.type == .keyDown {
            AppDelegate.shared?.repairFocusedTerminalKeyboardRoutingIfNeeded(
                window: self,
                event: event
            )
        }
#if DEBUG
        if event.type == .keyDown {
            focusRepairMs = (ProcessInfo.processInfo.systemUptime - focusRepairStart) * 1000.0
        }
        let folderGuardStart = event.type == .keyDown ? ProcessInfo.processInfo.systemUptime : 0
#endif
        defer {
            cmuxFirstResponderGuardCurrentEventContext = previousContextEvent
            cmuxFirstResponderGuardHitViewContext = previousContextHitView
            cmuxFirstResponderGuardContextWindowNumber = previousContextWindowNumber
        }

        guard shouldSuppressWindowMoveForFolderDrag(window: self, event: event),
              let contentView = self.contentView else {
#if DEBUG
            if event.type == .keyDown {
                folderGuardMs = (ProcessInfo.processInfo.systemUptime - folderGuardStart) * 1000.0
                let originalDispatchStart = ProcessInfo.processInfo.systemUptime
                cmux_sendEvent(event)
                originalDispatchMs = (ProcessInfo.processInfo.systemUptime - originalDispatchStart) * 1000.0
                return
            }
#endif
            cmux_sendEvent(event)
            return
        }
#if DEBUG
        if event.type == .keyDown {
            folderGuardMs = (ProcessInfo.processInfo.systemUptime - folderGuardStart) * 1000.0
        }
        let originalDispatchStart = event.type == .keyDown ? ProcessInfo.processInfo.systemUptime : 0
#endif

        let contentPoint = contentView.convert(event.locationInWindow, from: nil)
        let hitView = contentView.hitTest(contentPoint)
        let previousMovableState = isMovable
        if previousMovableState {
            isMovable = false
        }

        #if DEBUG
        let hitDesc = hitView.map { String(describing: type(of: $0)) } ?? "nil"
        dlog("window.sendEvent.folderDown suppress=1 hit=\(hitDesc) wasMovable=\(previousMovableState)")
        #endif

        cmux_sendEvent(event)
#if DEBUG
        if event.type == .keyDown {
            originalDispatchMs = (ProcessInfo.processInfo.systemUptime - originalDispatchStart) * 1000.0
        }
#endif

        if previousMovableState {
            isMovable = previousMovableState
        }

        #if DEBUG
        dlog("window.sendEvent.folderDown restore nowMovable=\(isMovable)")
        #endif
    }

    @objc func cmux_performKeyEquivalent(with event: NSEvent) -> Bool {
#if DEBUG
        let typingTimingStart = CmuxTypingTiming.start()
        defer {
            CmuxTypingTiming.logDuration(
                path: "window.performKeyEquivalent",
                startedAt: typingTimingStart,
                event: event
            )
        }
        let frType = self.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        dlog("performKeyEquiv: \(Self.keyDescription(event)) fr=\(frType)")
#endif

        // When the terminal surface is the first responder, prevent SwiftUI's
        // hosting view from consuming key events via performKeyEquivalent.
        // After a browser panel (WKWebView) has been in the responder chain,
        // SwiftUI's internal focus system can get into a broken state where it
        // intercepts key events in the content view hierarchy, returns true
        // (claiming consumption), but never actually fires the action closure.
        //
        // For non-Command keys: bypass the view hierarchy entirely and send
        // directly to the terminal so arrow keys, Ctrl+N/P, etc. reach keyDown.
        //
        // For Command keys: bypass the SwiftUI content view hierarchy and
        // dispatch directly to the main menu. No SwiftUI view should be handling
        // Command shortcuts when the terminal is focused — the local event monitor
        // (handleCustomShortcut) already handles app-level shortcuts, and anything
        // remaining should be menu items.
        let firstResponderGhosttyView = cmuxOwningGhosttyView(for: self.firstResponder)
        let firstResponderWebView = self.firstResponder.flatMap {
            Self.cmuxOwningWebView(for: $0, in: self, event: event)
        }
        let firstResponderHasMarkedText = browserResponderHasMarkedText(self.firstResponder)
        if let ghosttyView = firstResponderGhosttyView {
            // If the IME is composing and the key has no Cmd modifier, don't intercept —
            // let it flow through normal AppKit event dispatch so the input method can
            // process it. Cmd-based shortcuts should still work during composition since
            // Cmd is never part of IME input sequences.
            if ghosttyView.hasMarkedText(), !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
                return cmux_performKeyEquivalent(with: event)
            }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !flags.contains(.command) {
                let result = ghosttyView.performKeyEquivalent(with: event)
#if DEBUG
                dlog("  → ghostty direct: \(result)")
#endif
                return result
            }

            // Preserve Ghostty's terminal font-size shortcuts (Cmd +/−/0) when
            // the terminal is focused. Otherwise our browser menu shortcuts can
            // consume the event even when no browser panel is focused.
            if shouldRouteTerminalFontZoomShortcutToGhostty(
                firstResponderIsGhostty: true,
                flags: event.modifierFlags,
                chars: event.charactersIgnoringModifiers ?? "",
                keyCode: event.keyCode,
                literalChars: event.characters
            ) {
                ghosttyView.keyDown(with: event)
#if DEBUG
                dlog("zoom.shortcut stage=window.ghosttyKeyDownDirect event=\(Self.keyDescription(event)) handled=1")
#endif
                return true
            }
        }

        // Web forms rely on Return/Enter flowing through keyDown. If the original
        // NSWindow.performKeyEquivalent consumes Enter first, submission never reaches
        // WebKit. Route Return/Enter directly to the current first responder and
        // mark handled to avoid the AppKit alert sound path.
        if shouldDispatchBrowserReturnViaFirstResponderKeyDown(
            keyCode: event.keyCode,
            firstResponderIsBrowser: firstResponderWebView != nil,
            firstResponderHasMarkedText: firstResponderHasMarkedText,
            flags: event.modifierFlags
        ) {
            // Forwarding keyDown can re-enter performKeyEquivalent in WebKit/AppKit internals.
            // On re-entry, fall back to normal dispatch to avoid an infinite loop.
            if cmuxBrowserReturnForwardingDepth > 0 {
#if DEBUG
                dlog("  → browser Return/Enter reentry; using normal dispatch")
#endif
                return false
            }
            cmuxBrowserReturnForwardingDepth += 1
            defer { cmuxBrowserReturnForwardingDepth = max(0, cmuxBrowserReturnForwardingDepth - 1) }
#if DEBUG
            dlog("  → browser Return/Enter routed to firstResponder.keyDown")
#endif
            self.firstResponder?.keyDown(with: event)
            return true
        }

        // Some browser content (notably Google Docs) loses plain up/down when
        // NSWindow.performKeyEquivalent claims the arrow before WebKit sees
        // keyDown. Route those arrows directly to the first responder instead.
        if shouldDispatchBrowserArrowViaFirstResponderKeyDown(
            keyCode: event.keyCode,
            firstResponderIsBrowser: firstResponderWebView != nil,
            firstResponderHasMarkedText: firstResponderHasMarkedText,
            flags: event.modifierFlags
        ) {
            // Match the Return/Enter forwarding guard: AppKit/WebKit can re-enter
            // performKeyEquivalent while the synthesized keyDown is in flight.
            if cmuxBrowserArrowForwardingDepth > 0 {
#if DEBUG
                dlog("  → browser Up/Down reentry; using normal dispatch")
#endif
                return false
            }
            cmuxBrowserArrowForwardingDepth += 1
            defer { cmuxBrowserArrowForwardingDepth = max(0, cmuxBrowserArrowForwardingDepth - 1) }
#if DEBUG
            dlog("  → browser Up/Down routed to firstResponder.keyDown")
#endif
            self.firstResponder?.keyDown(with: event)
            return true
        }

        if let firstResponderWebView,
           shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst(
               event,
               responder: self.firstResponder,
               owningWebView: firstResponderWebView
           ) {
            let result = firstResponderWebView.performKeyEquivalent(with: event)
#if DEBUG
            if result {
                dlog("  → browser find command resolved before window menu path")
            } else {
                dlog("  → browser find command preflight left unclaimed; suppressing replay")
            }
#endif
            // The focused web view has already received this Find-family shortcut once.
            // Do not fall through into the original NSWindow.performKeyEquivalent path,
            // or WebKit can observe the same key equivalent a second time before AppKit
            // reaches keyDown/menu fallback.
            return true
        }

        if AppDelegate.shared?.handleBrowserSurfaceKeyEquivalent(event) == true {
#if DEBUG
            dlog("  → consumed by handleBrowserSurfaceKeyEquivalent")
#endif
            return true
        }

        // When the terminal is focused, skip the full NSWindow.performKeyEquivalent
        // (which walks the SwiftUI content view hierarchy) and dispatch Command-key
        // events directly to the main menu. This avoids the broken SwiftUI focus path.
        if firstResponderGhosttyView != nil,
           shouldRouteCommandEquivalentDirectlyToMainMenu(event),
           let mainMenu = NSApp.mainMenu {
            let consumedByMenu = mainMenu.performKeyEquivalent(with: event)
#if DEBUG
            if browserZoomShortcutTraceCandidate(
                flags: event.modifierFlags,
                chars: event.charactersIgnoringModifiers ?? "",
                keyCode: event.keyCode,
                literalChars: event.characters
            ) {
                dlog(
                    "zoom.shortcut stage=window.mainMenuBypass event=\(Self.keyDescription(event)) " +
                    "consumed=\(consumedByMenu ? 1 : 0) fr=GhosttyNSView"
                )
            }
#endif
            if !consumedByMenu {
                // Fall through to the original performKeyEquivalent path below.
            } else {
#if DEBUG
                dlog("  → consumed by mainMenu (bypassed SwiftUI)")
#endif
                return true
            }
        }

        let result = cmux_performKeyEquivalent(with: event)
#if DEBUG
        if result { dlog("  → consumed by original performKeyEquivalent") }
#endif
        return result
    }

    static func keyDescription(_ event: NSEvent) -> String {
        var parts: [String] = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { parts.append("Cmd") }
        if flags.contains(.shift) { parts.append("Shift") }
        if flags.contains(.option) { parts.append("Opt") }
        if flags.contains(.control) { parts.append("Ctrl") }
        let chars = event.charactersIgnoringModifiers ?? "?"
        parts.append("'\(chars)'(\(event.keyCode))")
        return parts.joined(separator: "+")
    }

    private static func cmuxOwningWebView(for responder: NSResponder) -> CmuxWebView? {
        if let webView = responder as? CmuxWebView {
            return webView
        }

        if let view = responder as? NSView,
           let webView = cmuxOwningWebView(for: view) {
            return webView
        }

        // NSTextView.delegate is unsafe-unretained in AppKit. Reading it here while
        // a responder chain is tearing down can trap with "unowned reference".
        var current = responder.nextResponder
        while let next = current {
            if let webView = next as? CmuxWebView {
                return webView
            }
            if let view = next as? NSView,
               let webView = cmuxOwningWebView(for: view) {
                return webView
            }
            current = next.nextResponder
        }

        return nil
    }

    private static func cmuxOwningWebView(
        for responder: NSResponder,
        in window: NSWindow,
        event: NSEvent?
    ) -> CmuxWebView? {
        // Browser find runs in the portal slot alongside the hosted WKWebView.
        // Treat its native field editor chain as browser chrome, not as web content,
        // so Cmd+F can move first responder into the find field while web focus is suppressed.
        if BrowserWindowPortalRegistry.searchOverlayPanelId(for: responder, in: window) != nil {
            return nil
        }

        if let webView = cmuxOwningWebView(for: responder) {
            return webView
        }

        guard let textView = responder as? NSTextView, textView.isFieldEditor else {
            return nil
        }

        if let event,
           let hitWebView = cmuxPointerHitWebView(in: window, event: event) {
            cmuxTrackFieldEditor(textView, owningWebView: hitWebView)
            return hitWebView
        }

        return cmuxTrackedOwningWebView(for: textView)
    }

    private static func cmuxOwningWebView(for view: NSView) -> CmuxWebView? {
        if let webView = view as? CmuxWebView {
            return webView
        }

        var current: NSView? = view.superview
        while let candidate = current {
            if let webView = candidate as? CmuxWebView {
                return webView
            }
            if String(describing: type(of: candidate)).contains("WindowBrowserSlotView"),
               let portalWebView = cmuxUniqueBrowserWebView(in: candidate) {
                // Portal-hosted browser chrome (for example the Cmd+F overlay) is a
                // sibling of the hosted WKWebView inside WindowBrowserSlotView, not a
                // descendant of it. Allow native text-entry controls in that slot to
                // acquire first responder directly, but keep generic sibling views
                // associated with the hosted web view so blocked browser focus policy
                // still protects inspector/overlay chrome from stray focus changes.
                if view === portalWebView || view.isDescendant(of: portalWebView) {
                    return portalWebView
                }
                if cmuxAllowsPortalSlotTextEntryFocus(view) {
                    return nil
                }
                return portalWebView
            }
            current = candidate.superview
        }

        return nil
    }

    private static func cmuxAllowsPortalSlotTextEntryFocus(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let candidate = current {
            if let textField = candidate as? NSTextField {
                return textField.isEditable || textField.acceptsFirstResponder
            }
            if let textView = candidate as? NSTextView {
                return textView.isEditable || textView.isSelectable || textView.isFieldEditor
            }
            current = candidate.superview
        }
        return false
    }

    private static func cmuxUniqueBrowserWebView(in root: NSView) -> CmuxWebView? {
        var stack: [NSView] = [root]
        var found: CmuxWebView?
        while let current = stack.popLast() {
            if let webView = current as? CmuxWebView {
                if found == nil {
                    found = webView
                } else if found !== webView {
                    return nil
                }
            }
            stack.append(contentsOf: current.subviews)
        }
        return found
    }

    private static func cmuxCurrentEvent(for window: NSWindow) -> NSEvent? {
#if DEBUG
        if let override = cmuxFirstResponderGuardCurrentEventOverride {
            return override
        }
#endif
        if cmuxFirstResponderGuardContextWindowNumber == window.windowNumber {
            return cmuxFirstResponderGuardCurrentEventContext
        }
        return NSApp.currentEvent
    }

    private static func cmuxHitViewInThemeFrame(in window: NSWindow, event: NSEvent) -> NSView? {
        guard let contentView = window.contentView,
              let themeFrame = contentView.superview else {
            return nil
        }
        let pointInTheme = themeFrame.convert(event.locationInWindow, from: nil)
        return themeFrame.hitTest(pointInTheme)
    }

    private static func cmuxHitViewInContentView(in window: NSWindow, event: NSEvent) -> NSView? {
        guard let contentView = window.contentView else {
            return nil
        }
        let pointInContent = contentView.convert(event.locationInWindow, from: nil)
        return contentView.hitTest(pointInContent)
    }

    private static func cmuxTopHitViewForEvent(in window: NSWindow, event: NSEvent) -> NSView? {
        if let hitInThemeFrame = cmuxHitViewInThemeFrame(in: window, event: event) {
            return hitInThemeFrame
        }
        return cmuxHitViewInContentView(in: window, event: event)
    }

    private static func cmuxHitViewForEventDispatch(in window: NSWindow, event: NSEvent) -> NSView? {
        if event.windowNumber != 0, event.windowNumber != window.windowNumber {
            return nil
        }
        if let eventWindow = event.window, eventWindow !== window {
            return nil
        }
        return cmuxTopHitViewForEvent(in: window, event: event)
    }

    private static func cmuxHitViewForCurrentEvent(in window: NSWindow, event: NSEvent) -> NSView? {
#if DEBUG
        if let override = cmuxFirstResponderGuardHitViewOverride {
            return override
        }
#endif
        if cmuxFirstResponderGuardContextWindowNumber == window.windowNumber,
           let contextHitView = cmuxFirstResponderGuardHitViewContext {
            return contextHitView
        }
        return cmuxTopHitViewForEvent(in: window, event: event)
    }

    private static func cmuxTrackFieldEditor(_ fieldEditor: NSTextView, owningWebView webView: CmuxWebView?) {
        if let webView {
            objc_setAssociatedObject(
                fieldEditor,
                &cmuxFieldEditorOwningWebViewAssociationKey,
                CmuxFieldEditorOwningWebViewBox(webView: webView),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        } else {
            objc_setAssociatedObject(
                fieldEditor,
                &cmuxFieldEditorOwningWebViewAssociationKey,
                nil,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    private static func cmuxTrackedOwningWebView(for fieldEditor: NSTextView) -> CmuxWebView? {
        guard let box = objc_getAssociatedObject(
            fieldEditor,
            &cmuxFieldEditorOwningWebViewAssociationKey
        ) as? CmuxFieldEditorOwningWebViewBox else {
            return nil
        }
        guard let webView = box.webView else {
            cmuxTrackFieldEditor(fieldEditor, owningWebView: nil)
            return nil
        }
        return webView
    }

    private static func cmuxIsPointerDownEvent(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return true
        default:
            return false
        }
    }

    private static func cmuxPointerHitWebView(in window: NSWindow, event: NSEvent) -> CmuxWebView? {
        guard cmuxIsPointerDownEvent(event) else { return nil }
        if event.windowNumber != 0, event.windowNumber != window.windowNumber {
            return nil
        }
        if let eventWindow = event.window, eventWindow !== window {
            return nil
        }
        if let portalWebView = BrowserWindowPortalRegistry.webViewAtWindowPoint(
            event.locationInWindow,
            in: window
        ) as? CmuxWebView {
            return portalWebView
        }
        guard let hitView = cmuxHitViewForCurrentEvent(in: window, event: event) else {
            return nil
        }
        return cmuxOwningWebView(for: hitView)
    }

    private static func cmuxShouldAllowPointerInitiatedWebViewFocus(
        window: NSWindow,
        webView: CmuxWebView,
        event: NSEvent?
    ) -> Bool {
        guard let event,
              let hitWebView = cmuxPointerHitWebView(in: window, event: event) else {
            return false
        }
        return hitWebView === webView
    }

}
