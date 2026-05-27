import AppKit
import SwiftUI
import Foundation
import Bonsplit
import CoreVideo
import Combine
import CoreServices
import Darwin

// MARK: - Tab Type Alias for Backwards Compatibility
// The old Tab class is replaced by Workspace
typealias Tab = Workspace

private final class WorkspaceGitMetadataWatcherCallbackBox: @unchecked Sendable {
    let handleEvent: @Sendable () -> Void

    init(handleEvent: @escaping @Sendable () -> Void) {
        self.handleEvent = handleEvent
    }
}

private let workspaceGitMetadataWatcherCallback: FSEventStreamCallback = { _, info, _, _, _, _ in
    guard let info else { return }
    let box = Unmanaged<WorkspaceGitMetadataWatcherCallbackBox>.fromOpaque(info).takeUnretainedValue()
    box.handleEvent()
}

private final class WorkspaceGitMetadataWatcher: @unchecked Sendable {
    struct Descriptor: Equatable, Sendable {
        let directory: String
        let watchedPaths: [String]
    }

    let descriptor: Descriptor

    private let queue = DispatchQueue(label: "com.cmux.workspace-git-metadata-watcher", qos: .utility)
    private let queueSpecificKey = DispatchSpecificKey<UInt8>()
    private var callbackBox: WorkspaceGitMetadataWatcherCallbackBox?
    private let onChange: @Sendable () -> Void
    private var stream: FSEventStreamRef?
    private var debounceWorkItem: DispatchWorkItem?

    init?(descriptor: Descriptor, onChange: @escaping @Sendable () -> Void) {
        guard !descriptor.watchedPaths.isEmpty else { return nil }
        self.descriptor = descriptor
        self.onChange = onChange
        queue.setSpecific(key: queueSpecificKey, value: 1)
        let callbackBox = WorkspaceGitMetadataWatcherCallbackBox { [weak self] in
            self?.scheduleChange()
        }
        self.callbackBox = callbackBox

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callbackBox).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            nil,
            workspaceGitMetadataWatcherCallback,
            &context,
            descriptor.watchedPaths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25,
            flags
        ) else {
            return nil
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            stop()
            return nil
        }
    }

    func stop() {
        if DispatchQueue.getSpecific(key: queueSpecificKey) != nil {
            stopOnQueue()
        } else {
            queue.sync {
                stopOnQueue()
            }
        }
    }

    private func stopOnQueue() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func scheduleChange() {
        if DispatchQueue.getSpecific(key: queueSpecificKey) != nil {
            scheduleChangeOnQueue()
        } else {
            queue.async { [weak self] in
                self?.scheduleChangeOnQueue()
            }
        }
    }

    private func scheduleChangeOnQueue() {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.onChange()
        }
        debounceWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    deinit {
        stop()
    }
}

enum NewWorkspacePlacement: String, CaseIterable, Identifiable {
    case top
    case afterCurrent
    case end

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .top:
            return String(localized: "workspace.placement.top", defaultValue: "Top")
        case .afterCurrent:
            return String(localized: "workspace.placement.afterCurrent", defaultValue: "After current")
        case .end:
            return String(localized: "workspace.placement.end", defaultValue: "End")
        }
    }

    var description: String {
        switch self {
        case .top:
            return String(
                localized: "workspace.placement.top.description",
                defaultValue: "Insert new workspaces at the top of the list."
            )
        case .afterCurrent:
            return String(
                localized: "workspace.placement.afterCurrent.description",
                defaultValue: "Insert new workspaces directly after the active workspace."
            )
        case .end:
            return String(
                localized: "workspace.placement.end.description",
                defaultValue: "Append new workspaces to the bottom of the list."
            )
        }
    }
}

enum WorkspaceAutoReorderSettings {
    static let key = "workspaceAutoReorderOnNotification"
    static let defaultValue = true

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: key) == nil {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }
}

enum WorkspaceOrderChangeNotificationKey {
    static let movedWorkspaceIds = "movedWorkspaceIds"
}

struct WorkspaceReorderPlanItem: Equatable {
    let workspaceId: UUID
    let fromIndex: Int
    let toIndex: Int
}

enum WorkspaceBatchReorderError: Error, Equatable {
    case duplicateWorkspace(UUID)
    case workspaceNotFound(UUID)
}

enum LastSurfaceCloseShortcutSettings {
    static let key = "closeWorkspaceOnLastSurfaceShortcut"
    // Keep the legacy stored meaning so existing values still map to the same
    // behavior. The default is flipped to preserve the current Close Tab shortcut behavior.
    static let defaultValue = true

    static func closesWorkspace(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: key) == nil {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }
}

enum SidebarBranchLayoutSettings {
    static let key = "sidebarBranchVerticalLayout"
    static let defaultVerticalLayout = true

    static func usesVerticalLayout(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: key) == nil {
            return defaultVerticalLayout
        }
        return defaults.bool(forKey: key)
    }
}

enum SidebarBranchDirectoryStackedSettings {
    static let key = "sidebarBranchDirectoryStacked"
    static let defaultStacked = false

    static func isStacked(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: key) == nil {
            return defaultStacked
        }
        return defaults.bool(forKey: key)
    }
}

enum SidebarPathLastSegmentSettings {
    static let key = "sidebarPathLastSegmentOnly"
    static let defaultLastSegmentOnly = false

    static func isLastSegmentOnly(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: key) == nil {
            return defaultLastSegmentOnly
        }
        return defaults.bool(forKey: key)
    }
}

enum SidebarWorkspaceDetailSettings {
    static let hideAllDetailsKey = "sidebarHideAllDetails"
    static let showWorkspaceDescriptionKey = "sidebarShowWorkspaceDescription"
    static let showNotificationMessageKey = "sidebarShowNotificationMessage"
    static let defaultHideAllDetails = false
    static let defaultShowWorkspaceDescription = true
    static let defaultShowNotificationMessage = true

    static func hidesAllDetails(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: hideAllDetailsKey) == nil {
            return defaultHideAllDetails
        }
        return defaults.bool(forKey: hideAllDetailsKey)
    }

    static func showsWorkspaceDescription(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: showWorkspaceDescriptionKey) == nil {
            return defaultShowWorkspaceDescription
        }
        return defaults.bool(forKey: showWorkspaceDescriptionKey)
    }

    static func showsNotificationMessage(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: showNotificationMessageKey) == nil {
            return defaultShowNotificationMessage
        }
        return defaults.bool(forKey: showNotificationMessageKey)
    }

    static func resolvedWorkspaceDescriptionVisibility(
        showWorkspaceDescription: Bool,
        hideAllDetails: Bool
    ) -> Bool {
        showWorkspaceDescription && !hideAllDetails
    }

    static func resolvedNotificationMessageVisibility(
        showNotificationMessage: Bool,
        hideAllDetails: Bool
    ) -> Bool {
        showNotificationMessage && !hideAllDetails
    }
}

enum SidebarPullRequestClickabilitySettings {
    static let key = "sidebarMakePullRequestClickable"
    static let defaultClickable = true

    static func isClickable(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: key) == nil {
            return defaultClickable
        }
        return defaults.bool(forKey: key)
    }
}

struct SidebarWorkspaceAuxiliaryDetailVisibility: Equatable {
    let showsMetadata: Bool
    let showsLog: Bool
    let showsProgress: Bool
    let showsBranchDirectory: Bool
    let showsPullRequests: Bool
    let showsPorts: Bool

    static let hidden = Self(
        showsMetadata: false,
        showsLog: false,
        showsProgress: false,
        showsBranchDirectory: false,
        showsPullRequests: false,
        showsPorts: false
    )

    static func resolved(
        showMetadata: Bool,
        showLog: Bool,
        showProgress: Bool,
        showBranchDirectory: Bool,
        showPullRequests: Bool,
        showPorts: Bool,
        hideAllDetails: Bool
    ) -> Self {
        guard !hideAllDetails else { return .hidden }
        return Self(
            showsMetadata: showMetadata,
            showsLog: showLog,
            showsProgress: showProgress,
            showsBranchDirectory: showBranchDirectory,
            showsPullRequests: showPullRequests,
            showsPorts: showPorts
        )
    }
}

enum SidebarActiveTabIndicatorStyle: String, CaseIterable, Identifiable {
    case leftRail
    case solidFill

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .leftRail:
            return String(localized: "sidebar.activeTabIndicator.leftRail", defaultValue: "Left Rail")
        case .solidFill:
            return String(localized: "sidebar.activeTabIndicator.solidFill", defaultValue: "Solid Fill")
        }
    }
}

enum SidebarActiveTabIndicatorSettings {
    static let styleKey = "sidebarActiveTabIndicatorStyle"
    static let defaultStyle: SidebarActiveTabIndicatorStyle = .leftRail

    static func resolvedStyle(rawValue: String?) -> SidebarActiveTabIndicatorStyle {
        guard let rawValue else { return defaultStyle }
        if let style = SidebarActiveTabIndicatorStyle(rawValue: rawValue) {
            return style
        }

        // Legacy values from earlier iterations map to the closest modern option.
        switch rawValue {
        case "rail":
            return .leftRail
        case "border", "wash", "lift", "typography", "washRail", "blueWashColorRail":
            return .solidFill
        default:
            return defaultStyle
        }
    }

    static func current(defaults: UserDefaults = .standard) -> SidebarActiveTabIndicatorStyle {
        resolvedStyle(rawValue: defaults.string(forKey: styleKey))
    }
}

enum WorkspacePlacementSettings {
    static let placementKey = "newWorkspacePlacement"
    static let defaultPlacement: NewWorkspacePlacement = .afterCurrent

    static func current(defaults: UserDefaults = .standard) -> NewWorkspacePlacement {
        guard let raw = defaults.string(forKey: placementKey),
              let placement = NewWorkspacePlacement(rawValue: raw) else {
            return defaultPlacement
        }
        return placement
    }

    static func effectivePlacement(
        placementOverride: NewWorkspacePlacement?,
        defaults: UserDefaults = .standard
    ) -> NewWorkspacePlacement {
        if let placementOverride {
            return placementOverride
        }
        if IMessageModeSettings.isEnabled(defaults: defaults) {
            return .top
        }
        return current(defaults: defaults)
    }

    static func insertionIndex(
        placement: NewWorkspacePlacement,
        selectedIndex: Int?,
        selectedIsPinned: Bool,
        pinnedCount: Int,
        totalCount: Int
    ) -> Int {
        let clampedTotalCount = max(0, totalCount)
        let clampedPinnedCount = max(0, min(pinnedCount, clampedTotalCount))

        switch placement {
        case .top:
            // Keep pinned workspaces grouped at the top by inserting ahead of unpinned items.
            return clampedPinnedCount
        case .end:
            return clampedTotalCount
        case .afterCurrent:
            guard let selectedIndex, clampedTotalCount > 0 else {
                return clampedTotalCount
            }
            let clampedSelectedIndex = max(0, min(selectedIndex, clampedTotalCount - 1))
            if selectedIsPinned {
                return clampedPinnedCount
            }
            return min(clampedSelectedIndex + 1, clampedTotalCount)
        }
    }
}

enum WorkspaceWorkingDirectoryInheritanceSettings {
    static let key = "workspaceInheritWorkingDirectory"
    static let defaultValue = true

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: key) != nil else {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }
}

struct WorkspaceTabColorEntry: Equatable, Identifiable {
    let name: String
    let hex: String

    var id: String { name }
}

enum WorkspaceTabColorSettings {
    static let paletteKey = "workspaceTabColor.colors"

    private static let legacyDefaultOverridesKey = "workspaceTabColor.defaultOverrides"
    private static let legacyCustomColorsKey = "workspaceTabColor.customColors"

    private static let originalPRPalette: [WorkspaceTabColorEntry] = [
        WorkspaceTabColorEntry(name: "Red", hex: "#C0392B"),
        WorkspaceTabColorEntry(name: "Crimson", hex: "#922B21"),
        WorkspaceTabColorEntry(name: "Orange", hex: "#A04000"),
        WorkspaceTabColorEntry(name: "Amber", hex: "#7D6608"),
        WorkspaceTabColorEntry(name: "Olive", hex: "#4A5C18"),
        WorkspaceTabColorEntry(name: "Green", hex: "#196F3D"),
        WorkspaceTabColorEntry(name: "Teal", hex: "#006B6B"),
        WorkspaceTabColorEntry(name: "Aqua", hex: "#0E6B8C"),
        WorkspaceTabColorEntry(name: "Blue", hex: "#1565C0"),
        WorkspaceTabColorEntry(name: "Navy", hex: "#1A5276"),
        WorkspaceTabColorEntry(name: "Indigo", hex: "#283593"),
        WorkspaceTabColorEntry(name: "Purple", hex: "#6A1B9A"),
        WorkspaceTabColorEntry(name: "Magenta", hex: "#AD1457"),
        WorkspaceTabColorEntry(name: "Rose", hex: "#880E4F"),
        WorkspaceTabColorEntry(name: "Brown", hex: "#7B3F00"),
        WorkspaceTabColorEntry(name: "Charcoal", hex: "#3E4B5E"),
    ]

    static var defaultPalette: [WorkspaceTabColorEntry] {
        originalPRPalette
    }

    static func palette(defaults: UserDefaults = .standard) -> [WorkspaceTabColorEntry] {
        let paletteMap = effectivePaletteMap(defaults: defaults)
        let builtInOrder = defaultPalette.compactMap { entry -> WorkspaceTabColorEntry? in
            guard let hex = paletteMap[entry.name] else { return nil }
            return WorkspaceTabColorEntry(name: entry.name, hex: hex)
        }
        let builtInNames = Set(defaultPalette.map(\.name))
        let customEntries = paletteMap
            .filter { !builtInNames.contains($0.key) }
            .sorted { lhs, rhs in
                lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
            }
            .map { WorkspaceTabColorEntry(name: $0.key, hex: $0.value) }
        return builtInOrder + customEntries
    }

    static func customPaletteEntries(defaults: UserDefaults = .standard) -> [WorkspaceTabColorEntry] {
        let builtInNames = Set(defaultPalette.map(\.name))
        return palette(defaults: defaults).filter { !builtInNames.contains($0.name) }
    }

    static func defaultColorHex(named name: String) -> String? {
        defaultPalette.first(where: { $0.name == name })?.hex
    }

    static func currentColorHex(named name: String, defaults: UserDefaults = .standard) -> String? {
        effectivePaletteMap(defaults: defaults)[name]
    }

    static func setColor(named name: String, hex: String, defaults: UserDefaults = .standard) {
        guard let normalizedName = normalizedColorName(name),
              let normalizedHex = normalizedHex(hex) else { return }

        var palette = editablePaletteMap(defaults: defaults)
        palette[normalizedName] = normalizedHex
        persistPaletteMap(palette, defaults: defaults)
    }

    static func removeColor(named name: String, defaults: UserDefaults = .standard) {
        guard let normalizedName = normalizedColorName(name) else { return }
        var palette = editablePaletteMap(defaults: defaults)
        palette.removeValue(forKey: normalizedName)
        persistPaletteMap(palette, defaults: defaults)
    }

    static func persistPaletteMap(_ rawPalette: [String: String], defaults: UserDefaults = .standard) {
        let normalizedPalette = normalizedPaletteMap(rawPalette)
        if normalizedPalette == defaultPaletteMap {
            defaults.removeObject(forKey: paletteKey)
        } else {
            defaults.set(normalizedPalette, forKey: paletteKey)
        }
        defaults.removeObject(forKey: legacyDefaultOverridesKey)
        defaults.removeObject(forKey: legacyCustomColorsKey)
    }

    static func backupPaletteMap(defaults: UserDefaults = .standard) -> [String: String]? {
        if let stored = storedPaletteMap(defaults: defaults) {
            return stored
        }
        return legacyPaletteMap(defaults: defaults)
    }

    static func resolvedPaletteMap(defaults: UserDefaults = .standard) -> [String: String] {
        effectivePaletteMap(defaults: defaults)
    }

    static func addCustomColor(_ hex: String, defaults: UserDefaults = .standard) -> String? {
        guard let normalized = normalizedHex(hex) else { return nil }
        var palette = editablePaletteMap(defaults: defaults)
        if palette.contains(where: { $0.value == normalized }) {
            return normalized
        }

        palette[nextCustomColorName(existingNames: Set(palette.keys))] = normalized
        persistPaletteMap(palette, defaults: defaults)
        return normalized
    }

    static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: paletteKey)
        defaults.removeObject(forKey: legacyDefaultOverridesKey)
        defaults.removeObject(forKey: legacyCustomColorsKey)
    }

    static func normalizedHex(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let body = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard body.count == 6 else { return nil }
        guard UInt64(body, radix: 16) != nil else { return nil }
        return "#" + body.uppercased()
    }

    static func displayColor(
        hex: String,
        colorScheme: ColorScheme,
        forceBright: Bool = false
    ) -> Color? {
        guard let color = displayNSColor(hex: hex, colorScheme: colorScheme, forceBright: forceBright) else {
            return nil
        }
        return Color(nsColor: color)
    }

    static func displayNSColor(
        hex: String,
        colorScheme: ColorScheme,
        forceBright: Bool = false
    ) -> NSColor? {
        guard let normalized = normalizedHex(hex),
              let baseColor = NSColor(hex: normalized) else {
            return nil
        }

        if forceBright || colorScheme == .dark {
            return brightenedForDarkAppearance(baseColor)
        }
        return baseColor
    }

    private static func effectivePaletteMap(defaults: UserDefaults) -> [String: String] {
        if let stored = storedPaletteMap(defaults: defaults) {
            return stored
        }
        if let legacy = legacyPaletteMap(defaults: defaults) {
            return legacy
        }
        return defaultPaletteMap
    }

    private static func editablePaletteMap(defaults: UserDefaults) -> [String: String] {
        if let stored = storedPaletteMap(defaults: defaults) {
            return stored
        }
        if let legacy = legacyPaletteMap(defaults: defaults) {
            return legacy
        }
        return defaultPaletteMap
    }

    private static func storedPaletteMap(defaults: UserDefaults) -> [String: String]? {
        guard let raw = defaults.dictionary(forKey: paletteKey) as? [String: String] else { return nil }
        return normalizedPaletteMap(raw)
    }

    private static func legacyPaletteMap(defaults: UserDefaults) -> [String: String]? {
        let hasLegacyOverrides = defaults.object(forKey: legacyDefaultOverridesKey) != nil
        let hasLegacyCustomColors = defaults.object(forKey: legacyCustomColorsKey) != nil
        guard hasLegacyOverrides || hasLegacyCustomColors else { return nil }

        var palette = defaultPaletteMap

        if let rawOverrides = defaults.dictionary(forKey: legacyDefaultOverridesKey) as? [String: String] {
            let validNames = Set(defaultPalette.map(\.name))
            for (name, hex) in rawOverrides {
                guard validNames.contains(name),
                      let normalized = normalizedHex(hex) else { continue }
                palette[name] = normalized
            }
        }

        if let rawCustomColors = defaults.array(forKey: legacyCustomColorsKey) as? [String] {
            var index = 1
            var seenCustomHexes: Set<String> = []
            for rawHex in rawCustomColors {
                guard let normalized = normalizedHex(rawHex),
                      seenCustomHexes.insert(normalized).inserted else { continue }
                let name = nextCustomColorName(
                    existingNames: Set(palette.keys),
                    startingAt: index
                )
                palette[name] = normalized
                index += 1
            }
        }

        return palette
    }

    private static func normalizedPaletteMap(_ rawPalette: [String: String]) -> [String: String] {
        var normalized: [String: String] = [:]
        for (rawName, rawHex) in rawPalette {
            guard let name = normalizedColorName(rawName),
                  let hex = normalizedHex(rawHex) else { continue }
            normalized[name] = hex
        }
        return normalized
    }

    private static var defaultPaletteMap: [String: String] {
        Dictionary(uniqueKeysWithValues: defaultPalette.map { ($0.name, $0.hex) })
    }

    private static func normalizedColorName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func nextCustomColorName(
        existingNames: Set<String>,
        startingAt initialIndex: Int = 1
    ) -> String {
        var index = max(1, initialIndex)
        while true {
            let candidate = "Custom \(index)"
            if !existingNames.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
                return candidate
            }
            index += 1
        }
    }

    private static func brightenedForDarkAppearance(_ color: NSColor) -> NSColor {
        let rgbColor = color.usingColorSpace(.sRGB) ?? color
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        rgbColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        let boostedBrightness = min(1, max(brightness, 0.62) + ((1 - brightness) * 0.28))
        // Preserve neutral grays when brightening to avoid introducing hue shifts.
        let boostedSaturation: CGFloat
        if saturation <= 0.08 {
            boostedSaturation = saturation
        } else {
            boostedSaturation = min(1, saturation + ((1 - saturation) * 0.12))
        }

        return NSColor(
            hue: hue,
            saturation: boostedSaturation,
            brightness: boostedBrightness,
            alpha: alpha
        )
    }
}

/// Coalesces repeated main-thread signals into one callback after a short delay.
/// Useful for notification storms where only the latest update matters.
final class NotificationBurstCoalescer {
    private let delay: TimeInterval
    private var isFlushScheduled = false
    private var pendingAction: (() -> Void)?

    init(delay: TimeInterval = 1.0 / 30.0) {
        self.delay = max(0, delay)
    }

    func signal(_ action: @escaping () -> Void) {
        precondition(Thread.isMainThread, "NotificationBurstCoalescer must be used on the main thread")
        pendingAction = action
        scheduleFlushIfNeeded()
    }

    private func scheduleFlushIfNeeded() {
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        precondition(Thread.isMainThread, "NotificationBurstCoalescer must be used on the main thread")
        isFlushScheduled = false
        guard let action = pendingAction else { return }
        pendingAction = nil
        action()
        if pendingAction != nil {
            scheduleFlushIfNeeded()
        }
    }
}

struct RecentlyClosedBrowserStack {
    private(set) var entries: [ClosedBrowserPanelRestoreSnapshot] = []
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var isEmpty: Bool {
        entries.isEmpty
    }

    var mostRecentClosedAt: Date? {
        entries.last?.closedAt
    }

    mutating func push(_ snapshot: ClosedBrowserPanelRestoreSnapshot) {
        entries.append(snapshot)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    mutating func pop() -> ClosedBrowserPanelRestoreSnapshot? {
        entries.popLast()
    }
}

#if DEBUG
// Sample the actual IOSurface-backed terminal layer at vsync cadence so UI tests can reliably
// catch a single compositor-frame blank flash and any transient compositor scaling (stretched text).
//
// This is DEBUG-only and used only for UI tests; no polling or display-link loops exist in normal app runtime.
fileprivate final class VsyncIOSurfaceTimelineState {
    struct Target {
        let label: String
        let sample: @MainActor () -> GhosttySurfaceScrollView.DebugFrameSample?
    }

    let frameCount: Int
    let closeFrame: Int
    let lock = NSLock()

    var framesWritten = 0
    var inFlight = false
    var finished = false

    var scheduledActions: [(frame: Int, action: () -> Void)] = []
    var nextActionIndex: Int = 0

    var targets: [Target] = []

    // Results
    var firstBlank: (label: String, frame: Int)?
    var firstSizeMismatch: (label: String, frame: Int, ios: String, expected: String)?
    var trace: [String] = []

    var link: CVDisplayLink?
    var continuation: CheckedContinuation<Void, Never>?

    init(frameCount: Int, closeFrame: Int) {
        self.frameCount = frameCount
        self.closeFrame = closeFrame
    }

    func tryBeginCapture() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if finished { return false }
        if inFlight { return false }
        inFlight = true
        return true
    }

    func endCapture() {
        lock.lock()
        inFlight = false
        lock.unlock()
    }

    func finish() {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume()
    }
}

fileprivate func cmuxVsyncIOSurfaceTimelineCallback(
    _ displayLink: CVDisplayLink,
    _ inNow: UnsafePointer<CVTimeStamp>,
    _ inOutputTime: UnsafePointer<CVTimeStamp>,
    _ flagsIn: CVOptionFlags,
    _ flagsOut: UnsafeMutablePointer<CVOptionFlags>,
    _ ctx: UnsafeMutableRawPointer?
) -> CVReturn {
    guard let ctx else { return kCVReturnSuccess }
    let st = Unmanaged<VsyncIOSurfaceTimelineState>.fromOpaque(ctx).takeUnretainedValue()
    if !st.tryBeginCapture() { return kCVReturnSuccess }

    // Sample on the main thread synchronously so we don't "miss" a single compositor frame.
    // (The previous Task/@MainActor hop could be delayed long enough to skip the blank frame.)
    DispatchQueue.main.sync {
        defer { st.endCapture() }
        guard st.framesWritten < st.frameCount else { return }

        while st.nextActionIndex < st.scheduledActions.count {
            let next = st.scheduledActions[st.nextActionIndex]
            if next.frame != st.framesWritten { break }
            st.nextActionIndex += 1
            next.action()
        }

        for t in st.targets {
            guard let s = t.sample() else { continue }

            let iosW = s.iosurfaceWidthPx
            let iosH = s.iosurfaceHeightPx
            let expW = s.expectedWidthPx
            let expH = s.expectedHeightPx
            let gravity = s.layerContentsGravity
            let hasDimensions = iosW > 0 && iosH > 0 && expW > 0 && expH > 0
            let dw = hasDimensions ? abs(iosW - expW) : 0
            let dh = hasDimensions ? abs(iosH - expH) : 0
            let hasSizeMismatch = hasDimensions && (dw > 2 || dh > 2)
            let stretchRisk = (gravity == CALayerContentsGravity.resize.rawValue)

            // Ignore setup/warmup frames before the close action. We only care about
            // regressions that happen at/after the close mutation.
            if st.firstBlank == nil, st.framesWritten >= st.closeFrame, s.isProbablyBlank {
                st.firstBlank = (label: t.label, frame: st.framesWritten)
            }

            if st.firstSizeMismatch == nil,
               st.framesWritten >= st.closeFrame,
               stretchRisk,
               hasSizeMismatch {
                st.firstSizeMismatch = (
                    label: t.label,
                    frame: st.framesWritten,
                    ios: "\(iosW)x\(iosH)",
                    expected: "\(expW)x\(expH)"
                )
            }

            if st.trace.count < 200 {
                st.trace.append("\(st.framesWritten):\(t.label):blank=\(s.isProbablyBlank ? 1 : 0):ios=\(iosW)x\(iosH):exp=\(expW)x\(expH):gravity=\(gravity):key=\(s.layerContentsKey)")
            }
        }

        st.framesWritten += 1
    }

    // Stop/resume outside the main-thread sync block to avoid reentrancy issues.
    if st.framesWritten >= st.frameCount, let link = st.link {
        CVDisplayLinkStop(link)
        st.finish()
        Unmanaged<VsyncIOSurfaceTimelineState>.fromOpaque(ctx).release()
    }

    return kCVReturnSuccess
}
#endif

@MainActor
class TabManager: ObservableObject {
    private enum WorkspacePullRequestSnapshot: Equatable {
        case deferred
        case unsupportedRepository
        case notFound
        case resolved(SidebarPullRequestState)
        case transientFailure
    }

    private struct InitialWorkspaceGitMetadataSnapshot: Equatable {
        let isRepository: Bool
        let branch: String?
        let isDirty: Bool
        let indexSignature: String?
        let indexContentSignature: String?
        let headSignature: String?
        let pullRequest: WorkspacePullRequestSnapshot
    }

    private struct ResolvedGitRepository: Equatable, Sendable {
        let workTreeRoot: String
        let gitDirectory: String
        let commonDirectory: String
    }

    private struct GitIndexEntryStat: Sendable {
        let path: String
        let mode: UInt32
        let objectID: String
        let mtimeSeconds: UInt32
        let mtimeNanoseconds: UInt32
        let size: UInt32
    }

    private struct GitIndexSnapshot: Sendable {
        let entries: [GitIndexEntryStat]
        let signature: String
        let contentSignature: String
    }

    private struct WorkspaceGitMetadataWatcherDescriptorRequest: Equatable, Sendable {
        let generation: UInt64
        let directory: String
    }

    struct CommandResult: Sendable {
        let stdout: String?
        let stderr: String?
        let exitStatus: Int32?
        let timedOut: Bool
        let executionError: String?
    }

#if DEBUG
    nonisolated(unsafe) static var commandRunnerForTesting: (
        @Sendable (String, String, [String], TimeInterval?) -> CommandResult?
    )?
#endif

    private struct WorkspaceGitProbeKey: Hashable, Sendable {
        let workspaceId: UUID
        let panelId: UUID
    }

    private enum WorkspaceGitProbeState: Equatable {
        case idle
        case inFlight(rerunPending: Bool)
    }

    private struct WorkspacePullRequestCandidate: Sendable {
        let workspaceId: UUID
        let panelId: UUID
        let branch: String
        let repoSlugs: [String]
    }

    private struct WorkspacePullRequestCandidateSeed: Sendable {
        let workspaceId: UUID
        let panelId: UUID
        let branch: String
        let directory: String?
    }

    private struct WorkspacePullRequestCandidateResolution: Sendable {
        let candidates: [WorkspacePullRequestCandidate]
        let candidateBranchesByRepo: [String: Set<String>]
        let repoDirectoriesBySlug: [String: String]
    }

    private struct WorkspacePullRequestResolvedItem: Sendable {
        let number: Int
        let urlString: String
        let statusRawValue: String
        let branch: String
    }

    private struct WorkspacePullRequestRefreshResult: Sendable {
        enum Resolution: Sendable {
            case unsupportedRepository
            case notFound
            case resolved(WorkspacePullRequestResolvedItem)
            case transientFailure
        }

        let workspaceId: UUID
        let panelId: UUID
        let resolution: Resolution
        let usedCachedRepoData: Bool
    }

    private struct WorkspacePullRequestRepoCacheEntry: Sendable {
        let fetchedAt: Date
        let pullRequestsByBranch: [String: GitHubPullRequestProbeItem]
        let knownAbsentBranches: Set<String>

        init(
            fetchedAt: Date,
            pullRequestsByBranch: [String: GitHubPullRequestProbeItem],
            knownAbsentBranches: Set<String> = []
        ) {
            self.fetchedAt = fetchedAt
            self.pullRequestsByBranch = pullRequestsByBranch
            self.knownAbsentBranches = knownAbsentBranches
        }
    }

    private enum WorkspacePullRequestRepoFetchResult: Sendable {
        case success(
            WorkspacePullRequestRepoCacheEntry,
            usedCache: Bool,
            transientBranches: Set<String>
        )
        case transientFailure
    }

    private enum WorkspacePullRequestBranchFetchResult: Sendable {
        case found(GitHubPullRequestProbeItem)
        case notFound
        case transientFailure
    }

    private struct WorkspacePullRequestBranchLookupOutcome: Sendable {
        let cacheEntry: WorkspacePullRequestRepoCacheEntry
        let transientBranches: Set<String>
    }

    private struct WorkspacePullRequestHTTPResponse: Sendable {
        let statusCode: Int
        let data: Data
    }

    private struct WorkspacePullRequestRESTItem: Decodable, Sendable {
        struct Ref: Decodable, Sendable {
            let ref: String
        }

        let number: Int
        let state: String
        let htmlURL: String
        let updatedAt: String?
        let mergedAt: String?
        let head: Ref
        let base: Ref?

        enum CodingKeys: String, CodingKey {
            case number
            case state
            case htmlURL = "html_url"
            case updatedAt = "updated_at"
            case mergedAt = "merged_at"
            case head
            case base
        }
    }

    struct GitHubPullRequestProbeItem: Decodable, Equatable, Sendable {
        let number: Int
        let state: String
        let url: String
        let updatedAt: String?
        let mergedAt: String?
        let headRefName: String?
        let baseRefName: String?

        init(
            number: Int,
            state: String,
            url: String,
            updatedAt: String?,
            mergedAt: String? = nil,
            headRefName: String? = nil,
            baseRefName: String? = nil
        ) {
            self.number = number
            self.state = state
            self.url = url
            self.updatedAt = updatedAt
            self.mergedAt = mergedAt
            self.headRefName = headRefName
            self.baseRefName = baseRefName
        }
    }

    /// The window that owns this TabManager. Set by AppDelegate.registerMainWindow().
    /// Used to apply title updates to the correct window instead of NSApp.keyWindow.
    weak var window: NSWindow?

    @Published var tabs: [Workspace] = []
    @Published private(set) var isWorkspaceCycleHot: Bool = false
    @Published private(set) var pendingBackgroundWorkspaceLoadIds: Set<UUID> = []
    @Published private(set) var mountedBackgroundWorkspaceLoadIds: Set<UUID> = []
    @Published private(set) var debugPinnedWorkspaceLoadIds: Set<UUID> = []

    /// Global monotonically increasing counter for CMUX_PORT ordinal assignment.
    /// Static so port ranges don't overlap across multiple windows (each window has its own TabManager).
    static var nextPortOrdinal: Int = 0
    private nonisolated static let initialWorkspaceGitProbeDelays: [TimeInterval] = [0, 0.5, 1.5, 3.0, 6.0, 10.0]
    private nonisolated static let workspaceGitMetadataFallbackRefreshInterval: TimeInterval = 5 * 60
    private nonisolated static let backgroundPollInterval: TimeInterval = 60
    private nonisolated static let selectedPollInterval: TimeInterval = 10
    private nonisolated static let workspacePullRequestRepoCacheLifetime: TimeInterval = 15
    private nonisolated static let workspacePullRequestRepoCachePruneLifetime: TimeInterval = 60
    private nonisolated static let workspacePullRequestRepoPageSize = 100
    private nonisolated static let workspacePullRequestRepoPageLimit = 2
    private nonisolated static let workspacePullRequestTerminalStateSweepInterval: TimeInterval = 15 * 60
    private nonisolated static let workspacePullRequestPollJitterFraction = 0.10
    private nonisolated static let workspacePullRequestProbeTimeout: TimeInterval = 5.0
    private nonisolated static let mergedPullRequestBadgeStaleAfter: TimeInterval = 14 * 24 * 60 * 60
    @Published var selectedTabId: UUID? {
        willSet {
#if DEBUG
            guard newValue != selectedTabId else {
                debugPendingWorkspaceSwitchTrigger = nil
                debugPendingWorkspaceSwitchTarget = nil
                debugPreparedWorkspaceSwitchTarget = nil
                return
            }

            if debugPreparedWorkspaceSwitchTarget == newValue {
                debugPreparedWorkspaceSwitchTarget = nil
                debugPendingWorkspaceSwitchTrigger = nil
                debugPendingWorkspaceSwitchTarget = nil
            } else {
                let trigger = (debugPendingWorkspaceSwitchTarget == newValue
                    ? debugPendingWorkspaceSwitchTrigger
                    : nil) ?? "direct"
                debugPendingWorkspaceSwitchTrigger = nil
                debugPendingWorkspaceSwitchTarget = nil
                debugBeginWorkspaceSwitch(
                    trigger: trigger,
                    from: selectedTabId,
                    to: newValue
                )
            }
#endif
        }
        didSet {
            guard selectedTabId != oldValue else { return }
            sentryBreadcrumb("workspace.switch", data: [
                "tabCount": tabs.count
            ])
            let previousTabId = oldValue
            if let previousTabId,
               let previousPanelId = focusedPanelId(for: previousTabId) {
                lastFocusedPanelByTab[previousTabId] = previousPanelId
            }
            if shouldRecordFocusHistory {
                if let previousTabId {
                    recordFocusInHistory(workspaceId: previousTabId, panelId: focusedPanelId(for: previousTabId))
                }
                if let selectedTabId,
                   let selectedWorkspace = tabs.first(where: { $0.id == selectedTabId }) {
                    let selectedEntry = FocusHistoryEntry(
                        workspaceId: selectedTabId,
                        panelId: lastFocusedPanelByTab[selectedTabId]
                    )
                    recordFocusInHistory(
                        workspaceId: selectedTabId,
                        panelId: resolvedFocusHistoryPanelId(for: selectedEntry, in: selectedWorkspace)
                    )
                }
            }
            publishCmuxWorkspaceSelectedChange(from: previousTabId)
            let notificationDismissalContext = pendingSelectedTabNotificationDismissContext ?? .activeFocus
            pendingSelectedTabNotificationDismissContext = nil
#if DEBUG
            let switchId = debugWorkspaceSwitchId
            let switchDtMs = debugWorkspaceSwitchStartTime > 0
                ? (CACurrentMediaTime() - debugWorkspaceSwitchStartTime) * 1000
                : 0
            cmuxDebugLog(
                "ws.select.didSet id=\(switchId) from=\(Self.debugShortWorkspaceId(previousTabId)) " +
                "to=\(Self.debugShortWorkspaceId(selectedTabId)) dt=\(Self.debugMsText(switchDtMs))"
            )
#endif
            selectionSideEffectsGeneration &+= 1
            let generation = selectionSideEffectsGeneration
            if !shouldRecordFocusHistory {
                focusHistorySuppressedSelectionSideEffectGenerations.insert(generation)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let suppressFocusHistory = self.focusHistorySuppressedSelectionSideEffectGenerations.remove(generation) != nil
                guard self.selectionSideEffectsGeneration == generation else { return }
                let applySelectionSideEffects = {
                    self.focusSelectedTabPanel(previousTabId: previousTabId)
                    self.updateWindowTitleForSelectedTab()
                    if let selectedTabId = self.selectedTabId {
                        self.dismissFocusedPanelNotificationIfActive(
                            tabId: selectedTabId,
                            context: notificationDismissalContext
                        )
                    }
                }
                if suppressFocusHistory {
                    self.withFocusHistoryRecordingSuppressed(applySelectionSideEffects)
                } else {
                    applySelectionSideEffects()
                }
#if DEBUG
                let dtMs = self.debugWorkspaceSwitchStartTime > 0
                    ? (CACurrentMediaTime() - self.debugWorkspaceSwitchStartTime) * 1000
                    : 0
                cmuxDebugLog(
                    "ws.select.asyncDone id=\(self.debugWorkspaceSwitchId) dt=\(Self.debugMsText(dtMs)) " +
                    "selected=\(Self.debugShortWorkspaceId(self.selectedTabId))"
                )
#endif
            }
        }
    }
    private var observers: [NSObjectProtocol] = []
    private var suppressFocusFlash = false
    private var pendingSelectedTabNotificationDismissContext: NotificationDismissalContext?
    private var lastFocusedPanelByTab: [UUID: UUID] = [:]
    private struct PanelTitleUpdateKey: Hashable {
        let tabId: UUID
        let panelId: UUID
    }
    private var pendingPanelTitleUpdates: [PanelTitleUpdateKey: String] = [:]
    private let panelTitleUpdateCoalescer = NotificationBurstCoalescer(delay: 1.0 / 30.0)
    private var recentlyClosedBrowsers = RecentlyClosedBrowserStack(capacity: 20)
    private let initialWorkspaceGitProbeQueue = DispatchQueue(
        label: "com.cmux.initial-workspace-git-probe",
        qos: .utility
    )
    private var workspaceGitProbeStateByKey: [WorkspaceGitProbeKey: WorkspaceGitProbeState] = [:]
    private var workspaceGitProbeTimersByKey: [WorkspaceGitProbeKey: [DispatchSourceTimer]] = [:]
    private var workspaceGitTrackedDirectoryByKey: [WorkspaceGitProbeKey: String] = [:]
    private var workspaceGitCleanIndexSignatureByKey: [WorkspaceGitProbeKey: String] = [:]
    private var workspaceGitCleanIndexContentSignatureByKey: [WorkspaceGitProbeKey: String] = [:]
    private var workspaceGitHeadSignatureByKey: [WorkspaceGitProbeKey: String] = [:]
    private var workspaceGitMetadataWatchersByKey: [WorkspaceGitProbeKey: WorkspaceGitMetadataWatcher] = [:]
    private var workspaceGitMetadataWatcherSourceDirectoryByKey: [WorkspaceGitProbeKey: String] = [:]
    private var workspaceGitMetadataWatcherDescriptorRequestsByKey: [WorkspaceGitProbeKey: WorkspaceGitMetadataWatcherDescriptorRequest] = [:]
    private var workspaceGitMetadataWatcherDescriptorGeneration: UInt64 = 0
    private var workspaceGitMetadataFallbackTimer: DispatchSourceTimer?
    private var lastSidebarGitMetadataWatchEnabled = SidebarWorkspaceDetailDefaults.watchGitStatusValue(defaults: .standard)
    private var workspacePullRequestProbeStateByKey: [WorkspaceGitProbeKey: WorkspaceGitProbeState] = [:]
    private var workspacePullRequestNextPollAtByKey: [WorkspaceGitProbeKey: Date] = [:]
    private var workspacePullRequestLastTerminalStateRefreshAtByKey: [WorkspaceGitProbeKey: Date] = [:]
    private var workspacePullRequestTransientFailureCountByKey: [WorkspaceGitProbeKey: Int] = [:]
    private var workspacePullRequestRepoCacheBySlug: [String: WorkspacePullRequestRepoCacheEntry] = [:]
    private var workspacePullRequestPollTimer: DispatchSourceTimer?
    private var workspacePullRequestRefreshTask: Task<Void, Never>?
    private var workspacePullRequestFollowUpShouldBypassRepoCache = false

    @Published private(set) var focusHistoryRevision: UInt64 = 0 {
        didSet {
            guard focusHistoryRevision != oldValue else { return }
            NotificationCenter.default.post(name: .tabManagerFocusHistoryRevisionDidChange, object: self)
        }
    }
    // Recent focus history for back/forward navigation across workspaces and panes.
    private var focusHistory: [FocusHistoryRecord] = []
    private var historyIndex: Int = -1
    private var focusHistoryRecordingSuppressionDepth = 0
    private var focusHistorySuppressedSelectionSideEffectGenerations: Set<UInt64> = []
    private var shouldRecordFocusHistory: Bool {
        focusHistoryRecordingSuppressionDepth == 0
    }
    private let maxHistorySize = 50
    private var selectionSideEffectsGeneration: UInt64 = 0
    private var workspaceCycleGeneration: UInt64 = 0
    private var workspaceCycleCooldownTask: Task<Void, Never>?
    private var pendingWorkspaceUnfocusTarget: (tabId: UUID, panelId: UUID)?
    private var sidebarSelectedWorkspaceIds: Set<UUID> = []
    private var currentWindowTabBarLeadingInset: CGFloat?
    private var closeConfirmationInFlight = false
    var confirmCloseHandler: ((String, String, Bool) -> Bool)?
    private var agentPIDSweepTimer: DispatchSourceTimer?
#if DEBUG
    private var debugWorkspaceSwitchCounter: UInt64 = 0
    private var debugWorkspaceSwitchId: UInt64 = 0
    private var debugWorkspaceSwitchStartTime: CFTimeInterval = 0
    private var debugPendingWorkspaceSwitchTrigger: String?
    private var debugPendingWorkspaceSwitchTarget: UUID?
    private var debugPreparedWorkspaceSwitchTarget: UUID?
#endif

#if DEBUG
    private var didSetupSplitCloseRightUITest = false
    private var didSetupUITestFocusShortcuts = false
    private var didSetupChildExitSplitUITest = false
    private var didSetupChildExitKeyboardUITest = false
    private var uiTestCancellables = Set<AnyCancellable>()
#endif

    init(
        initialWorkspaceTitle: String? = nil,
        initialWorkingDirectory: String? = nil,
        initialTerminalInput: String? = nil,
        autoWelcomeIfNeeded: Bool = true
    ) {
        addWorkspace(
            title: initialWorkspaceTitle,
            workingDirectory: initialWorkingDirectory,
            initialTerminalInput: initialTerminalInput,
            autoWelcomeIfNeeded: autoWelcomeIfNeeded
        )
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidSetTitle,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
                guard let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else { return }
                guard let title = notification.userInfo?[GhosttyNotificationKey.title] as? String else { return }
                enqueuePanelTitleUpdate(tabId: tabId, panelId: surfaceId, title: title)
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusSurface,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
                guard let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else { return }
                let explicitFocusIntent = notification.userInfo?[GhosttyNotificationKey.explicitFocusIntent] as? Bool ?? false
                let panelId = panelIdForFocusHistorySurface(surfaceId, workspaceId: tabId)
                if selectedTabId == tabId {
                    if explicitFocusIntent {
                        recordFocusInHistory(workspaceId: tabId, panelId: panelId)
                    } else {
                        recordImplicitFocusInHistory(workspaceId: tabId, panelId: panelId)
                    }
                }
                dismissPanelNotificationOnFocus(tabId: tabId, panelId: panelId, explicitFocusIntent: explicitFocusIntent)
                focusedSurfaceTitleDidChange(tabId: tabId)
            }
        })

        startAgentPIDSweepTimer()
        updateWorkspacePullRequestPollTimer()
        updateWorkspaceGitMetadataFallbackTimer()
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.sidebarGitMetadataWatchSettingsDidChange()
                self?.refreshTabCloseButtonVisibility()
            }
        })
#if DEBUG
        setupUITestFocusShortcutsIfNeeded()
        setupSplitCloseRightUITestIfNeeded()
        setupChildExitSplitUITestIfNeeded()
        setupChildExitKeyboardUITestIfNeeded()
#endif
    }

    deinit {
        workspaceCycleCooldownTask?.cancel()
        agentPIDSweepTimer?.cancel()
        workspacePullRequestPollTimer?.cancel()
        workspaceGitMetadataFallbackTimer?.cancel()
        workspacePullRequestRefreshTask?.cancel()
    }

    // MARK: - Agent PID Sweep

    /// Periodically checks agent PIDs associated with status entries.
    /// If a process has exited (SIGKILL, crash, etc.), clears the stale status entry.
    /// This is the safety net for cases where no hook fires (e.g. SIGKILL).
    private func startAgentPIDSweepTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.sweepStaleAgentPIDs()
            }
        }
        timer.resume()
        agentPIDSweepTimer = timer
    }

    private func updateWorkspacePullRequestPollTimer() {
        guard sidebarGitMetadataWatchEnabled else {
            workspacePullRequestPollTimer?.cancel()
            workspacePullRequestPollTimer = nil
            return
        }

        guard workspacePullRequestRefreshTask == nil else {
            workspacePullRequestPollTimer?.cancel()
            workspacePullRequestPollTimer = nil
            return
        }

        guard let nextPollAt = workspacePullRequestNextPollAtByKey.values.min() else {
            workspacePullRequestPollTimer?.cancel()
            workspacePullRequestPollTimer = nil
            return
        }

        if workspacePullRequestPollTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.refreshTrackedWorkspacePullRequestsIfNeeded(reason: "timer")
                }
            }
            timer.resume()
            workspacePullRequestPollTimer = timer
        }

        let delay = max(0.25, nextPollAt.timeIntervalSinceNow)
        workspacePullRequestPollTimer?.schedule(
            deadline: .now() + delay,
            repeating: .never,
            leeway: .milliseconds(250)
        )
    }

    private func updateWorkspaceGitMetadataFallbackTimer() {
        guard sidebarGitMetadataWatchEnabled,
              !workspaceGitTrackedDirectoryByKey.isEmpty else {
            workspaceGitMetadataFallbackTimer?.cancel()
            workspaceGitMetadataFallbackTimer = nil
            return
        }

        guard workspaceGitMetadataFallbackTimer == nil else {
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.setEventHandler { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.refreshTrackedWorkspaceGitMetadata(reason: "fallbackTimer")
            }
        }
        timer.schedule(
            deadline: .now() + Self.workspaceGitMetadataFallbackRefreshInterval,
            repeating: Self.workspaceGitMetadataFallbackRefreshInterval,
            leeway: .seconds(15)
        )
        timer.resume()
        workspaceGitMetadataFallbackTimer = timer
    }

    private func refreshTrackedWorkspaceGitMetadata(reason: String) {
        let activeProbeKeys = activeWorkspaceGitProbeKeys

        for workspace in tabs {
            for panelId in trackedWorkspaceGitMetadataPollCandidatePanelIds(
                in: workspace,
                activeProbeKeys: activeProbeKeys
            ) {
                scheduleWorkspaceGitMetadataRefreshIfPossible(
                    workspaceId: workspace.id,
                    panelId: panelId,
                    reason: reason
                )
            }
        }
    }

    private var sidebarGitMetadataWatchEnabled: Bool {
        SidebarWorkspaceDetailDefaults.watchGitStatusValue(defaults: .standard)
    }

    private func sidebarGitMetadataWatchSettingsDidChange() {
        let isEnabled = sidebarGitMetadataWatchEnabled
        guard isEnabled != lastSidebarGitMetadataWatchEnabled else {
            return
        }
        lastSidebarGitMetadataWatchEnabled = isEnabled

        guard isEnabled else {
            stopAllWorkspaceGitMetadataWatchers()
            workspaceGitMetadataFallbackTimer?.cancel()
            workspaceGitMetadataFallbackTimer = nil
            workspaceGitProbeStateByKey.removeAll()
            for timers in workspaceGitProbeTimersByKey.values {
                for timer in timers {
                    timer.setEventHandler {}
                    timer.cancel()
                }
            }
            workspaceGitProbeTimersByKey.removeAll()
            workspaceGitTrackedDirectoryByKey.removeAll()
            workspaceGitCleanIndexSignatureByKey.removeAll()
            workspaceGitCleanIndexContentSignatureByKey.removeAll()
            workspaceGitHeadSignatureByKey.removeAll()
            resetWorkspacePullRequestRefreshState()
            clearAllWorkspaceSidebarGitMetadata()
            return
        }

        restartWorkspaceGitMetadataWatching(reason: "gitWatchSettingEnabled")
        updateWorkspaceGitMetadataFallbackTimer()
    }

    private func restartWorkspaceGitMetadataWatching(reason: String) {
        for workspace in tabs where !workspace.isRemoteWorkspace {
            for panelId in workspace.panels.keys {
                guard workspace.terminalPanel(for: panelId) != nil else {
                    continue
                }
                if let directory = gitProbeDirectory(for: workspace, panelId: panelId) {
                    let key = WorkspaceGitProbeKey(workspaceId: workspace.id, panelId: panelId)
                    workspaceGitTrackedDirectoryByKey[key] = directory
                    updateWorkspaceGitMetadataWatcher(for: key, directory: directory)
                }
                scheduleWorkspaceGitMetadataRefreshIfPossible(
                    workspaceId: workspace.id,
                    panelId: panelId,
                    reason: reason
                )
            }
        }
        updateWorkspaceGitMetadataFallbackTimer()
    }

    private func updateWorkspaceGitMetadataWatcher(
        for key: WorkspaceGitProbeKey,
        directory: String
    ) {
        guard sidebarGitMetadataWatchEnabled else {
            stopWorkspaceGitMetadataWatcher(for: key)
            return
        }

        if workspaceGitMetadataWatcherSourceDirectoryByKey[key] == directory,
           workspaceGitMetadataWatchersByKey[key] != nil {
            if workspaceGitMetadataWatcherDescriptorRequestsByKey[key]?.directory != directory {
                workspaceGitMetadataWatcherDescriptorRequestsByKey.removeValue(forKey: key)
            }
            return
        }

        if workspaceGitMetadataWatcherDescriptorRequestsByKey[key]?.directory == directory {
            return
        }

        workspaceGitMetadataWatcherDescriptorGeneration &+= 1
        let request = WorkspaceGitMetadataWatcherDescriptorRequest(
            generation: workspaceGitMetadataWatcherDescriptorGeneration,
            directory: directory
        )
        workspaceGitMetadataWatcherDescriptorRequestsByKey[key] = request

        Task { [weak self] in
            let descriptor = await Task.detached(priority: .utility) {
                Self.workspaceGitMetadataWatcherDescriptor(for: directory)
            }.value
            await MainActor.run { [weak self] in
                self?.applyWorkspaceGitMetadataWatcherDescriptor(
                    descriptor,
                    for: key,
                    request: request
                )
            }
        }
    }

    private func applyWorkspaceGitMetadataWatcherDescriptor(
        _ descriptor: WorkspaceGitMetadataWatcher.Descriptor?,
        for key: WorkspaceGitProbeKey,
        request: WorkspaceGitMetadataWatcherDescriptorRequest
    ) {
        guard workspaceGitMetadataWatcherDescriptorRequestsByKey[key] == request else {
            return
        }
        workspaceGitMetadataWatcherDescriptorRequestsByKey.removeValue(forKey: key)

        guard sidebarGitMetadataWatchEnabled,
              workspaceGitTrackedDirectoryByKey[key] == request.directory,
              let descriptor else {
            stopWorkspaceGitMetadataWatcher(for: key)
            return
        }

        if workspaceGitMetadataWatchersByKey[key]?.descriptor == descriptor {
            workspaceGitMetadataWatcherSourceDirectoryByKey[key] = request.directory
            return
        }

        stopWorkspaceGitMetadataWatcher(for: key)
        workspaceGitMetadataWatchersByKey[key] = WorkspaceGitMetadataWatcher(
            descriptor: descriptor
        ) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scheduleWorkspaceGitMetadataRefreshIfPossible(
                    workspaceId: key.workspaceId,
                    panelId: key.panelId,
                    reason: "filesystemEvent"
                )
            }
        }
        workspaceGitMetadataWatcherSourceDirectoryByKey[key] = request.directory
    }

    private func stopWorkspaceGitMetadataWatcher(for key: WorkspaceGitProbeKey) {
        workspaceGitMetadataWatcherDescriptorRequestsByKey.removeValue(forKey: key)
        workspaceGitMetadataWatcherSourceDirectoryByKey.removeValue(forKey: key)
        workspaceGitMetadataWatchersByKey.removeValue(forKey: key)?.stop()
    }

    private func stopWorkspaceGitMetadataWatchers(workspaceId: UUID) {
        let keys = workspaceGitMetadataWatchersByKey.keys.filter { $0.workspaceId == workspaceId }
        for key in keys {
            stopWorkspaceGitMetadataWatcher(for: key)
        }
    }

    private func stopAllWorkspaceGitMetadataWatchers() {
        for watcher in workspaceGitMetadataWatchersByKey.values {
            watcher.stop()
        }
        workspaceGitMetadataWatchersByKey.removeAll()
        workspaceGitMetadataWatcherSourceDirectoryByKey.removeAll()
        workspaceGitMetadataWatcherDescriptorRequestsByKey.removeAll()
    }

    private func refreshTrackedWorkspacePullRequestsIfNeeded(
        reason: String,
        allowCachedResultsOverride: Bool? = nil
    ) {
        guard sidebarGitMetadataWatchEnabled else {
            resetWorkspacePullRequestRefreshState()
            clearAllWorkspaceSidebarGitMetadata()
            return
        }

        let now = Date()
        var candidateSeeds: [WorkspacePullRequestCandidateSeed] = []
        var requestedKeys: [WorkspaceGitProbeKey] = []
        var validKeys: Set<WorkspaceGitProbeKey> = []

        for workspace in tabs {
            for panelId in Set(workspace.panelGitBranches.keys).union(workspace.panelPullRequests.keys) {
                let key = WorkspaceGitProbeKey(workspaceId: workspace.id, panelId: panelId)
                validKeys.insert(key)
                let branch = Self.normalizedBranchName(
                    workspace.panelGitBranches[panelId]?.branch
                        ?? workspace.panelPullRequests[panelId]?.branch
                )
                guard let branch else {
                    clearWorkspacePullRequestTracking(for: key)
                    continue
                }

                if Self.shouldSkipWorkspacePullRequestLookup(branch: branch) {
                    workspace.clearPanelPullRequest(panelId: panelId)
                    clearWorkspacePullRequestTracking(for: key)
                    continue
                }

                guard shouldRefreshWorkspacePullRequest(
                    key: key,
                    now: now,
                    currentPullRequest: workspace.panelPullRequests[panelId]
                ) else {
                    continue
                }

                if case .inFlight = workspacePullRequestProbeStateByKey[key] {
                    markWorkspacePullRequestProbeRerunPending(
                        for: key,
                        bypassRepoCache: !Self.workspacePullRequestRefreshAllowsRepoCache(reason: reason)
                    )
                    continue
                }

                let candidateSeed = workspacePullRequestCandidateSeed(
                    workspace: workspace,
                    panelId: panelId,
                    branch: branch
                )
                candidateSeeds.append(candidateSeed)
                requestedKeys.append(key)
            }
        }

        pruneWorkspacePullRequestTracking(validKeys: validKeys)
        guard workspacePullRequestRefreshTask == nil else {
            updateWorkspacePullRequestPollTimer()
            return
        }
        guard !candidateSeeds.isEmpty else {
            updateWorkspacePullRequestPollTimer()
            return
        }
        workspacePullRequestPollTimer?.cancel()
        workspacePullRequestPollTimer = nil
        for key in requestedKeys {
            workspacePullRequestProbeStateByKey[key] = .inFlight(rerunPending: false)
        }

        let cacheBySlug = workspacePullRequestRepoCacheBySlug
        let allowCachedResults = allowCachedResultsOverride
            ?? Self.workspacePullRequestRefreshAllowsRepoCache(reason: reason)
        workspacePullRequestRefreshTask = Task.detached(priority: .utility) { [weak self] in
            let candidateResolution = await Self.resolveWorkspacePullRequestCandidateSeeds(candidateSeeds)
            guard !Task.isCancelled else { return }
            let repoResults = await Self.fetchWorkspacePullRequestRepoResults(
                repoDirectoriesBySlug: candidateResolution.repoDirectoriesBySlug,
                candidateBranchesByRepo: candidateResolution.candidateBranchesByRepo,
                cacheBySlug: cacheBySlug,
                now: now,
                allowCachedResults: allowCachedResults
            )
            let results = Self.resolveWorkspacePullRequestRefreshResults(
                candidates: candidateResolution.candidates,
                repoResults: repoResults
            )
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard !Task.isCancelled else { return }
                self.workspacePullRequestRefreshTask = nil
                self.applyWorkspacePullRequestRefreshResults(
                    results,
                    repoResults: repoResults,
                    requestedKeys: requestedKeys,
                    now: Date(),
                    reason: reason
                )
            }
        }
    }

    private func shouldRefreshWorkspacePullRequest(
        key: WorkspaceGitProbeKey,
        now: Date,
        currentPullRequest: SidebarPullRequestState?
    ) -> Bool {
        Self.shouldRefreshWorkspacePullRequest(
            now: now,
            nextPollAt: workspacePullRequestNextPollAtByKey[key],
            lastTerminalStateRefreshAt: workspacePullRequestLastTerminalStateRefreshAtByKey[key],
            currentPullRequestStatus: currentPullRequest?.status
        )
    }

    private func workspacePullRequestCandidateSeed(
        workspace: Workspace,
        panelId: UUID,
        branch: String
    ) -> WorkspacePullRequestCandidateSeed {
        let directory = gitProbeDirectory(for: workspace, panelId: panelId)
        return WorkspacePullRequestCandidateSeed(
            workspaceId: workspace.id,
            panelId: panelId,
            branch: branch,
            directory: directory
        )
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    private nonisolated static func resolveWorkspacePullRequestCandidateSeeds(
        _ seeds: [WorkspacePullRequestCandidateSeed]
    ) async -> WorkspacePullRequestCandidateResolution {
        var candidates: [WorkspacePullRequestCandidate] = []
        candidates.reserveCapacity(seeds.count)
        var candidateBranchesByRepo: [String: Set<String>] = [:]
        var repoDirectoriesBySlug: [String: String] = [:]
        var repoSlugsByDirectory: [String: [String]] = [:]

        for seed in seeds {
            let repoSlugs: [String]
            if let directory = seed.directory {
                if let cachedRepoSlugs = repoSlugsByDirectory[directory] {
                    repoSlugs = cachedRepoSlugs
                } else {
                    let resolvedRepoSlugs = await githubRepositorySlugs(directory: directory)
                    repoSlugsByDirectory[directory] = resolvedRepoSlugs
                    repoSlugs = resolvedRepoSlugs
                }
            } else {
                repoSlugs = []
            }

            candidates.append(
                WorkspacePullRequestCandidate(
                    workspaceId: seed.workspaceId,
                    panelId: seed.panelId,
                    branch: seed.branch,
                    repoSlugs: repoSlugs
                )
            )
            for repoSlug in repoSlugs {
                candidateBranchesByRepo[repoSlug, default: []].insert(seed.branch)
            }
            if let directory = seed.directory {
                for repoSlug in repoSlugs where repoDirectoriesBySlug[repoSlug] == nil {
                    repoDirectoriesBySlug[repoSlug] = directory
                }
            }
        }

        return WorkspacePullRequestCandidateResolution(
            candidates: candidates,
            candidateBranchesByRepo: candidateBranchesByRepo,
            repoDirectoriesBySlug: repoDirectoriesBySlug
        )
    }

    private func scheduleWorkspacePullRequestRefresh(
        workspaceId: UUID,
        panelId: UUID,
        reason: String
    ) {
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        guard sidebarGitMetadataWatchEnabled else {
            clearWorkspaceGitMetadata(for: key)
            return
        }
        let shouldBypassRepoCache = !Self.workspacePullRequestRefreshAllowsRepoCache(reason: reason)
        if shouldBypassRepoCache, workspacePullRequestRefreshTask != nil {
            workspacePullRequestFollowUpShouldBypassRepoCache = true
        }
        if case .inFlight = workspacePullRequestProbeStateByKey[key] {
            markWorkspacePullRequestProbeRerunPending(
                for: key,
                bypassRepoCache: shouldBypassRepoCache
            )
        } else {
            workspacePullRequestNextPollAtByKey[key] = .distantPast
        }
#if DEBUG
        cmuxDebugLog(
            "workspace.prRefresh.schedule workspace=\(workspaceId.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) reason=\(reason)"
        )
#endif
        refreshTrackedWorkspacePullRequestsIfNeeded(reason: reason)
    }

    private func applyWorkspacePullRequestRefreshResults(
        _ results: [WorkspacePullRequestRefreshResult],
        repoResults: [String: WorkspacePullRequestRepoFetchResult],
        requestedKeys: [WorkspaceGitProbeKey],
        now: Date,
        reason: String
    ) {
        for (repoSlug, repoResult) in repoResults {
            guard case .success(let cacheEntry, let usedCache, _) = repoResult,
                  !usedCache else {
                continue
            }
            workspacePullRequestRepoCacheBySlug[repoSlug] = cacheEntry
        }

        let requestedKeySet = Set(requestedKeys)
        let resultsByKey = Dictionary(
            uniqueKeysWithValues: results.map {
                (WorkspaceGitProbeKey(workspaceId: $0.workspaceId, panelId: $0.panelId), $0)
            }
        )
        var needsFollowUpPass = false

        defer {
            if needsFollowUpPass {
                let shouldBypassRepoCache = workspacePullRequestFollowUpShouldBypassRepoCache
                workspacePullRequestFollowUpShouldBypassRepoCache = false
                refreshTrackedWorkspacePullRequestsIfNeeded(
                    reason: "\(reason).followUp",
                    allowCachedResultsOverride: shouldBypassRepoCache ? false : nil
                )
            }
        }

        for key in requestedKeys {
            let rerunPending = workspacePullRequestProbeRerunPending(for: key)
            workspacePullRequestProbeStateByKey[key] = .idle
            if rerunPending {
                workspacePullRequestNextPollAtByKey[key] = .distantPast
                needsFollowUpPass = true
            }

            guard requestedKeySet.contains(key),
                  let result = resultsByKey[key] else {
                continue
            }

            if rerunPending,
               workspacePullRequestFollowUpShouldBypassRepoCache,
               result.usedCachedRepoData {
                continue
            }

            guard let workspace = tabs.first(where: { $0.id == result.workspaceId }),
                  workspace.panels[result.panelId] != nil else {
                clearWorkspacePullRequestTracking(for: key)
                continue
            }

            let priorPullRequest = workspace.panelPullRequests[result.panelId]
            let countsAsTerminalSweep = priorPullRequest.map { $0.status != .open } ?? false

            switch result.resolution {
            case .resolved(let resolvedPullRequest):
                workspacePullRequestTransientFailureCountByKey[key] = 0
                guard let status = SidebarPullRequestStatus(rawValue: resolvedPullRequest.statusRawValue),
                      let url = URL(string: resolvedPullRequest.urlString) else {
                    continue
                }
                workspace.updatePanelPullRequest(
                    panelId: result.panelId,
                    number: resolvedPullRequest.number,
                    label: "PR",
                    url: url,
                    status: status,
                    branch: resolvedPullRequest.branch,
                    isStale: false
                )
            case .notFound:
                workspacePullRequestTransientFailureCountByKey[key] = 0
                workspacePullRequestLastTerminalStateRefreshAtByKey.removeValue(forKey: key)
                if workspace.panelPullRequests[result.panelId] != nil {
                    workspace.clearPanelPullRequest(panelId: result.panelId)
                }
            case .unsupportedRepository:
                workspacePullRequestTransientFailureCountByKey[key] = 0
                workspacePullRequestLastTerminalStateRefreshAtByKey.removeValue(forKey: key)
                if workspace.panelPullRequests[result.panelId] != nil {
                    workspace.clearPanelPullRequest(panelId: result.panelId)
                }
            case .transientFailure:
                let nextFailureCount = (workspacePullRequestTransientFailureCountByKey[key] ?? 0) + 1
                workspacePullRequestTransientFailureCountByKey[key] = nextFailureCount
                if nextFailureCount >= 3,
                   let currentPullRequest = workspace.panelPullRequests[result.panelId] {
                    workspace.updatePanelPullRequest(
                        panelId: result.panelId,
                        number: currentPullRequest.number,
                        label: currentPullRequest.label,
                        url: currentPullRequest.url,
                        status: currentPullRequest.status,
                        branch: currentPullRequest.branch,
                        isStale: true
                    )
                }
            }

            scheduleNextWorkspacePullRequestPoll(
                key: key,
                workspace: workspace,
                panelId: result.panelId,
                now: now,
                resolution: result.resolution,
                countsAsTerminalSweep: countsAsTerminalSweep
            )
            if rerunPending {
                workspacePullRequestNextPollAtByKey[key] = .distantPast
            }

#if DEBUG
            let label: String = {
                switch result.resolution {
                case .unsupportedRepository:
                    return "unsupported"
                case .notFound:
                    return "none"
                case .transientFailure:
                    return "transientFailure"
                case .resolved(let resolvedPullRequest):
                    return "#\(resolvedPullRequest.number):\(resolvedPullRequest.statusRawValue)"
                }
            }()
            cmuxDebugLog(
                "workspace.prRefresh.apply workspace=\(result.workspaceId.uuidString.prefix(5)) " +
                "panel=\(result.panelId.uuidString.prefix(5)) result=\(label) reason=\(reason)"
            )
#endif
        }

        updateWorkspacePullRequestPollTimer()
    }

    private func scheduleNextWorkspacePullRequestPoll(
        key: WorkspaceGitProbeKey,
        workspace: Workspace,
        panelId: UUID,
        now: Date,
        resolution: WorkspacePullRequestRefreshResult.Resolution,
        countsAsTerminalSweep: Bool
    ) {
        if countsAsTerminalSweep {
            workspacePullRequestLastTerminalStateRefreshAtByKey[key] = now
        }

        if case .resolved(let resolvedPullRequest) = resolution,
           let status = SidebarPullRequestStatus(rawValue: resolvedPullRequest.statusRawValue),
           status != .open {
            workspacePullRequestLastTerminalStateRefreshAtByKey[key] = now
            workspacePullRequestNextPollAtByKey[key] = now.addingTimeInterval(Self.workspacePullRequestTerminalStateSweepInterval)
            return
        }

        if case .transientFailure = resolution,
           workspacePullRequestLastTerminalStateRefreshAtByKey[key] != nil {
            workspacePullRequestNextPollAtByKey[key] = now.addingTimeInterval(Self.workspacePullRequestTerminalStateSweepInterval)
            return
        }

        if case .unsupportedRepository = resolution {
            workspacePullRequestLastTerminalStateRefreshAtByKey.removeValue(forKey: key)
            workspacePullRequestNextPollAtByKey[key] = now.addingTimeInterval(Self.jitteredPollInterval(base: Self.backgroundPollInterval))
            return
        }

        workspacePullRequestLastTerminalStateRefreshAtByKey.removeValue(forKey: key)
        let baseInterval = isSelectedFocusedPanel(workspace: workspace, panelId: panelId)
            ? Self.selectedPollInterval
            : Self.backgroundPollInterval
        workspacePullRequestNextPollAtByKey[key] = now.addingTimeInterval(Self.jitteredPollInterval(base: baseInterval))
    }

    private func pruneWorkspacePullRequestTracking(validKeys: Set<WorkspaceGitProbeKey>) {
        workspacePullRequestNextPollAtByKey = workspacePullRequestNextPollAtByKey.filter { validKeys.contains($0.key) }
        workspacePullRequestProbeStateByKey = workspacePullRequestProbeStateByKey.filter { validKeys.contains($0.key) }
        workspacePullRequestLastTerminalStateRefreshAtByKey = workspacePullRequestLastTerminalStateRefreshAtByKey.filter { validKeys.contains($0.key) }
        workspacePullRequestTransientFailureCountByKey = workspacePullRequestTransientFailureCountByKey.filter { validKeys.contains($0.key) }
        let repoCacheCutoff = Date().addingTimeInterval(-Self.workspacePullRequestRepoCachePruneLifetime)
        workspacePullRequestRepoCacheBySlug = workspacePullRequestRepoCacheBySlug.filter {
            $0.value.fetchedAt >= repoCacheCutoff
        }
        updateWorkspacePullRequestPollTimer()
    }

    private func clearWorkspacePullRequestTracking(for key: WorkspaceGitProbeKey) {
        workspacePullRequestNextPollAtByKey.removeValue(forKey: key)
        workspacePullRequestProbeStateByKey.removeValue(forKey: key)
        workspacePullRequestLastTerminalStateRefreshAtByKey.removeValue(forKey: key)
        workspacePullRequestTransientFailureCountByKey.removeValue(forKey: key)
        updateWorkspacePullRequestPollTimer()
    }

    private func clearWorkspacePullRequestTracking(workspaceId: UUID) {
        workspacePullRequestNextPollAtByKey = workspacePullRequestNextPollAtByKey.filter { $0.key.workspaceId != workspaceId }
        workspacePullRequestProbeStateByKey = workspacePullRequestProbeStateByKey.filter { $0.key.workspaceId != workspaceId }
        workspacePullRequestLastTerminalStateRefreshAtByKey = workspacePullRequestLastTerminalStateRefreshAtByKey.filter { $0.key.workspaceId != workspaceId }
        workspacePullRequestTransientFailureCountByKey = workspacePullRequestTransientFailureCountByKey.filter { $0.key.workspaceId != workspaceId }
        updateWorkspacePullRequestPollTimer()
    }

    private func resetWorkspacePullRequestRefreshState() {
        workspacePullRequestRefreshTask?.cancel()
        workspacePullRequestRefreshTask = nil
        workspacePullRequestProbeStateByKey.removeAll()
        workspacePullRequestNextPollAtByKey.removeAll()
        workspacePullRequestLastTerminalStateRefreshAtByKey.removeAll()
        workspacePullRequestTransientFailureCountByKey.removeAll()
        workspacePullRequestRepoCacheBySlug.removeAll()
        workspacePullRequestFollowUpShouldBypassRepoCache = false
        updateWorkspacePullRequestPollTimer()
    }

    private var activeWorkspaceGitProbeKeys: Set<WorkspaceGitProbeKey> {
        Set(workspaceGitProbeStateByKey.compactMap { key, state in
            guard case .inFlight = state else { return nil }
            return key
        })
    }

    private func markWorkspaceGitProbeRerunPending(for key: WorkspaceGitProbeKey) {
        guard case .inFlight(let rerunPending) = workspaceGitProbeStateByKey[key],
              !rerunPending else {
            return
        }
        workspaceGitProbeStateByKey[key] = .inFlight(rerunPending: true)
    }

    private func workspaceGitProbeRerunPending(for key: WorkspaceGitProbeKey) -> Bool {
        guard case .inFlight(let rerunPending) = workspaceGitProbeStateByKey[key] else {
            return false
        }
        return rerunPending
    }

    private func markWorkspacePullRequestProbeRerunPending(
        for key: WorkspaceGitProbeKey,
        bypassRepoCache: Bool
    ) {
        guard case .inFlight(let rerunPending) = workspacePullRequestProbeStateByKey[key],
              !rerunPending else {
            if bypassRepoCache {
                workspacePullRequestFollowUpShouldBypassRepoCache = true
            }
            return
        }
        workspacePullRequestProbeStateByKey[key] = .inFlight(rerunPending: true)
        if bypassRepoCache {
            workspacePullRequestFollowUpShouldBypassRepoCache = true
        }
    }

    private func workspacePullRequestProbeRerunPending(for key: WorkspaceGitProbeKey) -> Bool {
        guard case .inFlight(let rerunPending) = workspacePullRequestProbeStateByKey[key] else {
            return false
        }
        return rerunPending
    }

    private func isSelectedFocusedPanel(workspace: Workspace, panelId: UUID) -> Bool {
        selectedWorkspace?.id == workspace.id && selectedWorkspace?.focusedPanelId == panelId
    }

    private nonisolated static func jitteredPollInterval(base: TimeInterval) -> TimeInterval {
        let jitter = base * Self.workspacePullRequestPollJitterFraction
        return base + Double.random(in: -jitter...jitter)
    }

    nonisolated static func workspacePullRequestRefreshAllowsRepoCache(reason: String) -> Bool {
        let periodicPrefixes = [
            "periodicPoll",
            "selectedPeriodicPoll",
            "timer",
        ]
        return periodicPrefixes.contains { prefix in
            reason == prefix || reason.hasPrefix("\(prefix).")
        }
    }

    nonisolated static func shouldRefreshWorkspacePullRequest(
        now: Date,
        nextPollAt: Date?,
        lastTerminalStateRefreshAt: Date?,
        currentPullRequestStatus: SidebarPullRequestStatus?
    ) -> Bool {
        let nextPollAt = nextPollAt ?? .distantPast
        if nextPollAt <= now {
            return true
        }

        guard let currentPullRequestStatus,
              currentPullRequestStatus != .open else {
            return false
        }

        let lastTerminalRefreshAt = lastTerminalStateRefreshAt ?? .distantPast
        return now.timeIntervalSince(lastTerminalRefreshAt) >= Self.workspacePullRequestTerminalStateSweepInterval
    }

    func refreshTrackedWorkspaceGitMetadataForTesting() {
        refreshTrackedWorkspaceGitMetadata(reason: "test")
    }

    func sidebarGitMetadataWatchSettingsDidChangeForTesting() {
        sidebarGitMetadataWatchSettingsDidChange()
    }

    func trackedWorkspaceGitMetadataPollCandidatePanelIdsForTesting(workspaceId: UUID) -> Set<UUID> {
        let activeProbeKeys = activeWorkspaceGitProbeKeys
        guard let workspace = tabs.first(where: { $0.id == workspaceId }) else {
            return []
        }
        return trackedWorkspaceGitMetadataPollCandidatePanelIds(
            in: workspace,
            activeProbeKeys: activeProbeKeys
        )
    }

    func activeWorkspaceGitProbePanelIdsForTesting(workspaceId: UUID) -> Set<UUID> {
        let probeKeys = Set(workspaceGitProbeStateByKey.keys.filter { $0.workspaceId == workspaceId })
            .union(workspaceGitProbeTimersByKey.keys.filter { $0.workspaceId == workspaceId })
        return Set(probeKeys.map(\.panelId))
    }

    private func trackedWorkspaceGitMetadataPollCandidatePanelIds(
        in workspace: Workspace,
        activeProbeKeys: Set<WorkspaceGitProbeKey>
    ) -> Set<UUID> {
        var candidatePanelIds = Set(workspace.panelGitBranches.keys)
        candidatePanelIds.formUnion(workspace.panelPullRequests.keys)
        // Only keep background polling panels whose current directory has already
        // proven to yield sidebar git metadata. Initial multi-attempt probes handle
        // startup races; this avoids polling non-repo directories forever.
        candidatePanelIds.formUnion(
            workspace.panels.keys.compactMap { panelId in
                guard let currentDirectory = gitProbeDirectory(for: workspace, panelId: panelId) else {
                    return nil
                }
                let probeKey = WorkspaceGitProbeKey(workspaceId: workspace.id, panelId: panelId)
                guard workspaceGitTrackedDirectoryByKey[probeKey] == currentDirectory else {
                    return nil
                }
                return panelId
            }
        )

        if candidatePanelIds.isEmpty,
           let focusedPanelId = workspace.focusedPanelId,
           (workspace.gitBranch != nil || workspace.pullRequest != nil),
           gitProbeDirectory(for: workspace, panelId: focusedPanelId) != nil {
            candidatePanelIds.insert(focusedPanelId)
        }

        return Set(candidatePanelIds.filter { panelId in
            let probeKey = WorkspaceGitProbeKey(workspaceId: workspace.id, panelId: panelId)
            return !activeProbeKeys.contains(probeKey)
        })
    }

    private func sweepStaleAgentPIDs() {
        for tab in tabs {
            var keysToRemove: [String] = []
            for (key, pid) in tab.agentPIDs {
                guard pid > 0 else {
                    keysToRemove.append(key)
                    continue
                }
                // kill(pid, 0) probes process liveness without sending a signal.
                // ESRCH = process doesn't exist (stale). EPERM = process exists
                // but we lack permission (not stale, keep tracking).
                errno = 0
                if kill(pid, 0) == -1, POSIXErrorCode(rawValue: errno) == .ESRCH {
                    keysToRemove.append(key)
                }
            }
            if !keysToRemove.isEmpty {
                for key in keysToRemove {
                    tab.clearAgentPID(key: key, clearStatus: true, refreshPorts: false)
                }
                let remainingAgentPIDs = Set(tab.agentPIDs.values.compactMap { $0 > 0 ? Int($0) : nil })
                PortScanner.shared.refreshAgentPorts(workspaceId: tab.id, agentPIDs: remainingAgentPIDs)
                // Also clear stale notifications (e.g. "Doing well, thanks!")
                // left behind when Claude was killed without SessionEnd firing.
                AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: tab.id)
            }
        }
    }

    private func gitProbeDirectory(for workspace: Workspace, panelId: UUID) -> String? {
        // Match the sidebar directory fallback chain so hidden/background panels can
        // still probe git metadata before OSC 7 has reported a live cwd.
        let rawDirectory = workspace.panelDirectories[panelId]
            ?? workspace.terminalPanel(for: panelId)?.requestedWorkingDirectory
            ?? (workspace.focusedPanelId == panelId ? workspace.currentDirectory : nil)
        return rawDirectory.flatMap(normalizedWorkingDirectory)
    }

    func scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
        workspaceId: UUID,
        panelId: UUID,
        reason: String = "initial"
    ) {
        guard let workspace = tabs.first(where: { $0.id == workspaceId }),
              !workspace.isRemoteWorkspace else {
            return
        }
        scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: reason,
            delays: Self.initialWorkspaceGitProbeDelays
        )
    }

    private func scheduleWorkspaceGitMetadataRefreshIfPossible(
        workspaceId: UUID,
        panelId: UUID,
        reason: String,
        delays: [TimeInterval] = [0]
    ) {
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        guard sidebarGitMetadataWatchEnabled else {
            clearWorkspaceGitMetadata(for: key)
            return
        }
        guard let workspace = tabs.first(where: { $0.id == workspaceId }),
              workspace.panels[panelId] != nil,
              let directory = gitProbeDirectory(for: workspace, panelId: panelId) else {
            return
        }

        scheduleWorkspaceGitMetadataRefresh(
            workspaceId: workspaceId,
            panelId: panelId,
            directory: directory,
            delays: delays,
            reason: reason
        )
    }

    func wireClosedBrowserTracking(for workspace: Workspace) {
        workspace.onClosedBrowserPanel = { [weak self] snapshot in
            self?.recentlyClosedBrowsers.push(snapshot)
        }
    }

    private func unwireClosedBrowserTracking(for workspace: Workspace) {
        workspace.onClosedBrowserPanel = nil
    }

    var selectedWorkspace: Workspace? {
        guard let selectedTabId else { return nil }
        return tabs.first(where: { $0.id == selectedTabId })
    }

    // Keep selectedTab as convenience alias
    var selectedTab: Workspace? { selectedWorkspace }

    // MARK: - Surface/Panel Compatibility Layer

    /// Returns the focused terminal surface for the selected workspace
    var selectedSurface: TerminalSurface? {
        selectedWorkspace?.focusedTerminalPanel?.surface
    }

    /// Returns the focused panel's terminal panel (if it is a terminal)
    var selectedTerminalPanel: TerminalPanel? {
        selectedWorkspace?.focusedTerminalPanel
    }

    private var selectedWorkspaceTerminalPanels: [TerminalPanel] {
        selectedWorkspace?.panels.values.compactMap { $0 as? TerminalPanel } ?? []
    }

    var isFindVisible: Bool {
        selectedTerminalPanel?.searchState != nil || focusedBrowserPanel?.searchState != nil
    }

    var canUseSelectionForFind: Bool {
        selectedTerminalPanel?.hasSelection() == true
    }

    @discardableResult
    func startSearch() -> Bool {
        if let panel = selectedTerminalPanel {
            let hadExistingSearch = panel.searchState != nil
            panel.hostedView.preparePanelFocusIntentForActivation(.findField)
            let recoveredNeedle = hadExistingSearch ? "" : panel.surface.lastSearchNeedle
            let handled = startOrFocusTerminalSearch(panel.surface, initialNeedle: recoveredNeedle) { surface in
                NotificationCenter.default.post(
                    name: .ghosttySearchFocus,
                    object: surface,
                    userInfo: [FindFocusNotificationKey.selectAll: !hadExistingSearch && !recoveredNeedle.isEmpty]
                )
            }
#if DEBUG
            cmuxDebugLog(
                "find.startSearch workspace=\(panel.workspaceId.uuidString.prefix(5)) " +
                "panel=\(panel.id.uuidString.prefix(5)) existing=\(hadExistingSearch ? "yes" : "no") " +
                "handled=\(handled ? 1 : 0) " +
                "firstResponder=\(String(describing: panel.surface.uiWindow?.firstResponder))"
            )
#endif
            return handled
        }
        guard let browserPanel = focusedBrowserPanel else { return false }
        browserPanel.startFind()
        return browserPanel.searchState != nil
    }

    func searchSelection() {
        guard let panel = selectedTerminalPanel else { return }
        if panel.searchState == nil {
            panel.searchState = TerminalSurface.SearchState()
        }
#if DEBUG
        cmuxDebugLog(
            "find.searchSelection workspace=\(panel.workspaceId.uuidString.prefix(5)) " +
            "panel=\(panel.id.uuidString.prefix(5))"
        )
#endif
        NotificationCenter.default.post(name: .ghosttySearchFocus, object: panel.surface)
        _ = panel.performBindingAction("search_selection")
    }

    func findNext() {
        if let panel = selectedTerminalPanel {
            _ = panel.performBindingAction("search:next")
            return
        }

        focusedBrowserPanel?.findNext()
    }

    func findPrevious() {
        if let panel = selectedTerminalPanel {
            _ = panel.performBindingAction("search:previous")
            return
        }

        focusedBrowserPanel?.findPrevious()
    }

    @discardableResult
    func toggleFocusedTerminalCopyMode() -> Bool {
        guard let panel = selectedTerminalPanel else { return false }
        return panel.surface.toggleKeyboardCopyMode()
    }

    @discardableResult
    func toggleFocusedTerminalTextBox() -> Bool {
        guard let panel = selectedTerminalPanel else { return false }
        return panel.toggleTextBoxInput()
    }

    @discardableResult
    func focusFocusedTerminalTextBoxInputOrTerminal() -> Bool {
        guard let panel = selectedTerminalPanel else { return false }
        return panel.focusTextBoxInputOrTerminal()
    }

    @discardableResult
    func attachFileToFocusedTerminalTextBoxInput() -> Bool {
        guard let panel = selectedTerminalPanel else { return false }
        return panel.attachFileToTextBoxInput()
    }

    @discardableResult
    func consumeFocusedTerminalTextBoxHideEscapeIfArmed(in window: NSWindow?) -> Bool {
        guard let focusedPanel = selectedTerminalPanel else {
            clearFocusedTerminalTextBoxHideEscapeArm()
            return false
        }
        let consumed = focusedPanel.consumeTextBoxHideEscapeIfArmed(in: window)
        guard !consumed else { return true }
        for panel in selectedWorkspaceTerminalPanels {
            if panel === focusedPanel { continue }
            panel.clearTextBoxHideEscapeArm()
        }
        return false
    }

    func clearFocusedTerminalTextBoxHideEscapeArm() {
        for panel in selectedWorkspaceTerminalPanels {
            panel.clearTextBoxHideEscapeArm()
        }
    }

    func hideFind() {
        if let panel = selectedTerminalPanel {
            panel.searchState = nil
            return
        }

        focusedBrowserPanel?.hideFind()
    }

    func makeWorkspaceForCreation(
        title: String,
        workingDirectory: String?,
        portOrdinal: Int,
        configTemplate: CmuxSurfaceConfigTemplate?,
        initialTerminalCommand: String?,
        initialTerminalInput: String? = nil,
        initialTerminalEnvironment: [String: String]
    ) -> Workspace {
        Workspace(
            title: title,
            workingDirectory: workingDirectory,
            portOrdinal: portOrdinal,
            configTemplate: configTemplate,
            initialTerminalCommand: initialTerminalCommand,
            initialTerminalInput: initialTerminalInput,
            initialTerminalEnvironment: initialTerminalEnvironment
        )
    }

    func applyCreationChromeInheritance(
        to newWorkspace: Workspace,
        from sourceWorkspace: Workspace?
    ) {
        // Sidebar-toggle relayout updates the live Bonsplit leading inset so minimal-mode
        // workspaces reserve traffic-light space. New workspaces need that same inset
        // copied immediately because creation itself does not trigger the resync path.
        let inheritedLeadingInset = currentWindowTabBarLeadingInset
            ?? sourceWorkspace?.bonsplitController.configuration.appearance.tabBarLeadingInset
        guard let inheritedLeadingInset else { return }
        applyTabBarLeadingInset(inheritedLeadingInset, to: newWorkspace)
    }

    func syncWorkspaceTabBarLeadingInset(_ inset: CGFloat) {
        let normalizedInset = max(0, inset)
        currentWindowTabBarLeadingInset = normalizedInset
        for tab in tabs {
            applyTabBarLeadingInset(normalizedInset, to: tab)
        }
    }

    private func applyTabBarLeadingInset(_ inset: CGFloat, to workspace: Workspace) {
        if workspace.bonsplitController.configuration.appearance.tabBarLeadingInset != inset {
            workspace.bonsplitController.configuration.appearance.tabBarLeadingInset = inset
        }
    }

    /// Test seam for mutating live workspace state after the creation snapshot is captured.
    func didCaptureWorkspaceCreationSnapshot() {}

#if DEBUG
    func maybeMutateSelectionDuringWorkspaceCreationForDev(
        snapshot: WorkspaceCreationSnapshot
    ) {
        let env = ProcessInfo.processInfo.environment
        let isEnabled: Bool = {
            if let raw = env["CMUX_DEV_MUTATE_WORKSPACE_SELECTION_DURING_CREATION"] {
                return raw == "1" || raw.caseInsensitiveCompare("true") == .orderedSame
            }
            return UserDefaults.standard.bool(forKey: "cmuxDevMutateWorkspaceSelectionDuringCreation")
        }()
        guard isEnabled,
              let selectedTabId = snapshot.selectedTabId,
              let targetId = snapshot.tabs.lazy.map(\.id).first(where: { $0 != selectedTabId }),
              tabs.contains(where: { $0.id == targetId }) else {
            return
        }
        cmuxDebugLog(
            "workspace.create.devSelectionMutation from=\(selectedTabId.uuidString.prefix(5)) " +
            "to=\(targetId.uuidString.prefix(5))"
        )
        self.selectedTabId = targetId
    }
#endif

    @discardableResult
    func addWorkspace(
        title: String? = nil,
        workingDirectory overrideWorkingDirectory: String? = nil,
        initialTerminalCommand: String? = nil,
        initialTerminalInput: String? = nil,
        initialTerminalEnvironment: [String: String] = [:],
        inheritWorkingDirectory: Bool = true,
        select: Bool = true,
        eagerLoadTerminal: Bool = false,
        placementOverride: NewWorkspacePlacement? = nil,
        autoWelcomeIfNeeded: Bool = true
    ) -> Workspace {
        let sourceWorkspace = selectedWorkspace
        let capturedTabs = tabs
        // Snapshot the selected tab from the pinned workspace instead of rereading the
        // @Published selectedTabId storage after the inheritance helpers. The arm64 Nightly
        // Cmd+N crash is in PublishedSubject.value.getter on that second getter read.
        let capturedSelectedTabId = sourceWorkspace?.id
        // Keep both the source workspace and the pre-creation workspace array alive for the
        // entire creation path. Release ARC can otherwise drop retains early across the
        // helper/insertion chain, which reintroduces use-after-free crashes in optimized builds.
        return withExtendedLifetime((capturedTabs, sourceWorkspace)) {
            let dir = inheritWorkingDirectory
                ? implicitWorkingDirectoryForNewWorkspace(from: sourceWorkspace)
                : nil
            let font = inheritedTerminalFontPointsForNewWorkspace(workspace: sourceWorkspace)
            let snapshot = workspaceCreationSnapshotLite(
                currentTabs: capturedTabs,
                currentSelectedTabId: capturedSelectedTabId,
                preferredWorkingDirectory: dir,
                inheritedTerminalFontPoints: font
            )
            didCaptureWorkspaceCreationSnapshot()
#if DEBUG
            maybeMutateSelectionDuringWorkspaceCreationForDev(snapshot: snapshot)
#endif
            let nextTabCount = snapshot.tabs.count + 1
            sentryBreadcrumb("workspace.create", data: ["tabCount": nextTabCount])
            let explicitWorkingDirectory = normalizedWorkingDirectory(overrideWorkingDirectory)
            let workingDirectory = explicitWorkingDirectory ?? snapshot.preferredWorkingDirectory
            let inheritedConfig = workspaceCreationConfigTemplate(
                inheritedTerminalFontPoints: snapshot.inheritedTerminalFontPoints
            )
            // Resolve placement against the pre-creation snapshot before Workspace init
            // boots terminal state. The ssh/new-workspace path can otherwise crash while
            // reading @Published placement state from existing workspaces mid-creation.
            let insertIndex = newTabInsertIndex(snapshot: snapshot, placementOverride: placementOverride)
            let ordinal = Self.nextPortOrdinal
            Self.nextPortOrdinal += 1
            let newWorkspace = makeWorkspaceForCreation(
                title: title ?? "Terminal \(nextTabCount)",
                workingDirectory: workingDirectory,
                portOrdinal: ordinal,
                configTemplate: inheritedConfig,
                initialTerminalCommand: initialTerminalCommand,
                initialTerminalInput: initialTerminalInput,
                initialTerminalEnvironment: initialTerminalEnvironment
            )
            applyCreationChromeInheritance(
                to: newWorkspace,
                from: sourceWorkspace ?? capturedTabs.first
            )
            newWorkspace.owningTabManager = self
            if title != nil {
                newWorkspace.setCustomTitle(title)
            }
            wireClosedBrowserTracking(for: newWorkspace)
            if eagerLoadTerminal && !select {
                requestBackgroundWorkspaceLoad(for: newWorkspace.id)
            }
            // Apply insertion to the current live array so post-snapshot closes/reorders
            // are preserved instead of reintroducing stale workspace instances.
            var updatedTabs = tabs
            if insertIndex >= 0 && insertIndex <= updatedTabs.count {
                updatedTabs.insert(newWorkspace, at: insertIndex)
            } else {
                updatedTabs.append(newWorkspace)
            }
            tabs = updatedTabs
            if let terminalPanel = newWorkspace.focusedTerminalPanel {
                scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
                    workspaceId: newWorkspace.id,
                    panelId: terminalPanel.id
                )
            }
            if eagerLoadTerminal {
                if select {
                    newWorkspace.focusedTerminalPanel?.surface.requestBackgroundSurfaceStartIfNeeded()
                }
            }
            publishCmuxWorkspaceCreated(newWorkspace, selected: select)
            publishCmuxInitialSurfaceCreated(newWorkspace, selected: select)
            if select {
#if DEBUG
                debugPrimeWorkspaceSwitchTrigger("create", to: newWorkspace.id)
#endif
                selectedTabId = newWorkspace.id
                NotificationCenter.default.post(
                    name: .ghosttyDidFocusTab,
                    object: nil,
                    userInfo: [GhosttyNotificationKey.tabId: newWorkspace.id]
                )
            }
#if DEBUG
            UITestRecorder.incrementInt("addTabInvocations")
            UITestRecorder.record([
                "tabCount": String(updatedTabs.count),
                "selectedTabId": select ? newWorkspace.id.uuidString : (snapshot.selectedTabId?.uuidString ?? "")
            ])
#endif
            if autoWelcomeIfNeeded && select && !UserDefaults.standard.bool(forKey: WelcomeSettings.shownKey) {
                if let appDelegate = AppDelegate.shared {
                    appDelegate.sendWelcomeCommandWhenReady(to: newWorkspace, markShownOnSend: true)
                } else {
                    sendWelcomeWhenReady(to: newWorkspace)
                }
            }
            return newWorkspace
        }
    }

    @MainActor
    private func sendWelcomeWhenReady(to workspace: Workspace) {
        if let terminalPanel = workspace.focusedTerminalPanel,
           terminalPanel.surface.surface != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                UserDefaults.standard.set(true, forKey: WelcomeSettings.shownKey)
                terminalPanel.sendText("cmux welcome\n")
            }
            return
        }

        var resolved = false
        var readyObserver: NSObjectProtocol?
        var panelsCancellable: AnyCancellable?

        func finishIfReady() {
            guard !resolved,
                  let terminalPanel = workspace.focusedTerminalPanel,
                  terminalPanel.surface.surface != nil else { return }
            resolved = true
            if let readyObserver {
                NotificationCenter.default.removeObserver(readyObserver)
            }
            panelsCancellable?.cancel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                UserDefaults.standard.set(true, forKey: WelcomeSettings.shownKey)
                terminalPanel.sendText("cmux welcome\n")
            }
        }

        panelsCancellable = workspace.$panels
            .map { _ in () }
            .sink { _ in
                Task { @MainActor in
                    finishIfReady()
                }
            }
        readyObserver = NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: nil,
            queue: .main
        ) { note in
            guard let workspaceId = note.userInfo?["workspaceId"] as? UUID,
                  workspaceId == workspace.id else { return }
            Task { @MainActor in
                finishIfReady()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            Task { @MainActor in
                if let readyObserver, !resolved {
                    NotificationCenter.default.removeObserver(readyObserver)
                }
                if !resolved {
                    panelsCancellable?.cancel()
                }
            }
        }
    }

    private func scheduleInitialWorkspaceGitMetadataRefresh(
        workspaceId: UUID,
        panelId: UUID,
        directory: String
    ) {
        scheduleWorkspaceGitMetadataRefresh(
            workspaceId: workspaceId,
            panelId: panelId,
            directory: directory,
            delays: Self.initialWorkspaceGitProbeDelays,
            reason: "initial"
        )
    }

    private func scheduleWorkspaceGitMetadataRefresh(
        workspaceId: UUID,
        panelId: UUID,
        directory: String,
        delays: [TimeInterval],
        reason: String
    ) {
        let normalizedDirectory = normalizeDirectory(directory)
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        cancelWorkspaceGitProbeTimers(for: key)
        if workspaceGitProbeStateByKey[key] == nil {
            workspaceGitProbeStateByKey[key] = .idle
        }

#if DEBUG
        cmuxDebugLog(
            "workspace.gitProbe.schedule workspace=\(workspaceId.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) dir=\(normalizedDirectory) reason=\(reason)"
        )
#endif

        var timers: [DispatchSourceTimer] = []
        for (index, delay) in delays.enumerated() {
            let isLastAttempt = index == delays.count - 1
            let timer = DispatchSource.makeTimerSource(queue: initialWorkspaceGitProbeQueue)
            timer.schedule(deadline: .now() + delay, repeating: .never)
            timer.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in
                    self?.beginWorkspaceGitMetadataProbeAttempt(
                        probeKey: key,
                        expectedDirectory: normalizedDirectory,
                        isLastAttempt: isLastAttempt
                    )
                }
            }
            timers.append(timer)
            timer.resume()
        }
        workspaceGitProbeTimersByKey[key] = timers
    }

    private func beginWorkspaceGitMetadataProbeAttempt(
        probeKey: WorkspaceGitProbeKey,
        expectedDirectory: String,
        isLastAttempt: Bool
    ) {
        switch workspaceGitProbeStateByKey[probeKey] ?? .idle {
        case .idle:
            workspaceGitProbeStateByKey[probeKey] = .inFlight(rerunPending: false)
        case .inFlight:
            markWorkspaceGitProbeRerunPending(for: probeKey)
            return
        }

        Task.detached(priority: .utility) { [weak self] in
            let snapshot = await Self.initialWorkspaceGitMetadataSnapshot(for: expectedDirectory)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.applyWorkspaceGitMetadataSnapshot(
                    snapshot,
                    probeKey: probeKey,
                    expectedDirectory: expectedDirectory,
                    isLastAttempt: isLastAttempt
                )
            }
        }
    }

    private func cancelWorkspaceGitProbeTimers(for key: WorkspaceGitProbeKey) {
        guard let timers = workspaceGitProbeTimersByKey.removeValue(forKey: key) else {
            return
        }
        for timer in timers {
            timer.setEventHandler {}
            timer.cancel()
        }
    }

    private func clearWorkspaceGitProbe(_ key: WorkspaceGitProbeKey) {
        workspaceGitProbeStateByKey.removeValue(forKey: key)
        workspaceGitCleanIndexSignatureByKey.removeValue(forKey: key)
        workspaceGitCleanIndexContentSignatureByKey.removeValue(forKey: key)
        workspaceGitHeadSignatureByKey.removeValue(forKey: key)
        cancelWorkspaceGitProbeTimers(for: key)
        stopWorkspaceGitMetadataWatcher(for: key)
        updateWorkspaceGitMetadataFallbackTimer()
    }

    private func finishWorkspaceGitProbeAttempt(_ key: WorkspaceGitProbeKey) {
        workspaceGitProbeStateByKey.removeValue(forKey: key)
        cancelWorkspaceGitProbeTimers(for: key)
    }

    private func clearWorkspaceGitMetadata(for key: WorkspaceGitProbeKey) {
        clearWorkspaceGitProbe(key)
        workspaceGitTrackedDirectoryByKey.removeValue(forKey: key)
        updateWorkspaceGitMetadataFallbackTimer()
        clearWorkspacePullRequestTracking(for: key)
        guard let workspace = tabs.first(where: { $0.id == key.workspaceId }) else {
            return
        }
        workspace.clearPanelGitBranch(panelId: key.panelId)
        workspace.clearPanelPullRequest(panelId: key.panelId)
    }

    private func clearAllWorkspaceSidebarGitMetadata() {
        for workspace in tabs {
            workspace.clearSidebarGitMetadata()
        }
    }

    private func clearWorkspaceGitProbes(workspaceId: UUID) {
        let keys = Set(workspaceGitProbeStateByKey.keys.filter { $0.workspaceId == workspaceId })
            .union(workspaceGitProbeTimersByKey.keys.filter { $0.workspaceId == workspaceId })
        for key in keys {
            clearWorkspaceGitProbe(key)
        }
        workspaceGitTrackedDirectoryByKey = workspaceGitTrackedDirectoryByKey.filter { key, _ in
            key.workspaceId != workspaceId
        }
        workspaceGitCleanIndexSignatureByKey = workspaceGitCleanIndexSignatureByKey.filter { key, _ in
            key.workspaceId != workspaceId
        }
        workspaceGitCleanIndexContentSignatureByKey = workspaceGitCleanIndexContentSignatureByKey.filter { key, _ in
            key.workspaceId != workspaceId
        }
        workspaceGitHeadSignatureByKey = workspaceGitHeadSignatureByKey.filter { key, _ in
            key.workspaceId != workspaceId
        }
        stopWorkspaceGitMetadataWatchers(workspaceId: workspaceId)
        updateWorkspaceGitMetadataFallbackTimer()
        clearWorkspacePullRequestTracking(workspaceId: workspaceId)
    }

    private func applyWorkspaceGitMetadataSnapshot(
        _ snapshot: InitialWorkspaceGitMetadataSnapshot,
        probeKey: WorkspaceGitProbeKey,
        expectedDirectory: String,
        isLastAttempt: Bool
    ) {
        let wasInFlight: Bool = {
            if case .inFlight = workspaceGitProbeStateByKey[probeKey] { return true }
            return false
        }()
        let resolvedPullRequest: SidebarPullRequestState? = {
            guard case .resolved(let pullRequest) = snapshot.pullRequest else { return nil }
            return pullRequest
        }()
        let shouldTrackGitDirectory = snapshot.isRepository || resolvedPullRequest != nil
        let shouldFinishProbe = shouldStopWorkspaceGitMetadataRefresh(snapshot) || isLastAttempt
        let shouldStopTrackingGitDirectory = shouldFinishProbe && !shouldTrackGitDirectory
        var didClearProbe = false
        defer {
            if wasInFlight, !didClearProbe {
                let rerunPending = workspaceGitProbeRerunPending(for: probeKey)
                if rerunPending {
                    workspaceGitProbeStateByKey[probeKey] = .idle
                    if shouldFinishProbe {
                        cancelWorkspaceGitProbeTimers(for: probeKey)
                    }
                    scheduleWorkspaceGitMetadataRefreshIfPossible(
                        workspaceId: probeKey.workspaceId,
                        panelId: probeKey.panelId,
                        reason: "rerunPending"
                    )
                } else if shouldStopTrackingGitDirectory {
                    clearWorkspaceGitProbe(probeKey)
                } else if shouldFinishProbe {
                    finishWorkspaceGitProbeAttempt(probeKey)
                } else {
                    workspaceGitProbeStateByKey[probeKey] = .idle
                }
            }
        }

        guard wasInFlight else { return }
        guard let workspace = tabs.first(where: { $0.id == probeKey.workspaceId }) else {
            clearWorkspaceGitProbe(probeKey)
            didClearProbe = true
            return
        }
        guard workspace.panels[probeKey.panelId] != nil else {
            clearWorkspaceGitProbe(probeKey)
            didClearProbe = true
            return
        }

        guard let currentDirectory = gitProbeDirectory(for: workspace, panelId: probeKey.panelId) else {
            clearWorkspaceGitProbe(probeKey)
            didClearProbe = true
            return
        }
        if currentDirectory != expectedDirectory {
            clearWorkspaceGitProbe(probeKey)
            didClearProbe = true
#if DEBUG
            cmuxDebugLog(
                "workspace.gitProbe.skip workspace=\(probeKey.workspaceId.uuidString.prefix(5)) " +
                "panel=\(probeKey.panelId.uuidString.prefix(5)) reason=directoryChanged " +
                "expected=\(expectedDirectory) current=\(currentDirectory)"
            )
#endif
            return
        }

        workspace.updatePanelDirectory(panelId: probeKey.panelId, directory: expectedDirectory)

        if shouldTrackGitDirectory {
            workspaceGitTrackedDirectoryByKey[probeKey] = expectedDirectory
            updateWorkspaceGitMetadataWatcher(for: probeKey, directory: expectedDirectory)
        } else {
            workspaceGitTrackedDirectoryByKey.removeValue(forKey: probeKey)
            stopWorkspaceGitMetadataWatcher(for: probeKey)
        }
        updateWorkspaceGitMetadataFallbackTimer()

        let nextBranch = snapshot.branch
        if let nextBranch {
            if let headSignature = snapshot.headSignature {
                if let previousHeadSignature = workspaceGitHeadSignatureByKey[probeKey],
                   previousHeadSignature != headSignature {
                    workspaceGitCleanIndexSignatureByKey.removeValue(forKey: probeKey)
                    workspaceGitCleanIndexContentSignatureByKey.removeValue(forKey: probeKey)
                }
                workspaceGitHeadSignatureByKey[probeKey] = headSignature
            } else {
                workspaceGitHeadSignatureByKey.removeValue(forKey: probeKey)
            }
            var isDirty = snapshot.isDirty
            if !isDirty,
               let indexSignature = snapshot.indexSignature,
               let cleanIndexSignature = workspaceGitCleanIndexSignatureByKey[probeKey],
               cleanIndexSignature != indexSignature {
                if let indexContentSignature = snapshot.indexContentSignature,
                   let cleanIndexContentSignature = workspaceGitCleanIndexContentSignatureByKey[probeKey],
                   cleanIndexContentSignature == indexContentSignature {
                    workspaceGitCleanIndexSignatureByKey[probeKey] = indexSignature
                } else {
                    isDirty = true
                }
            }
            workspace.updatePanelGitBranch(
                panelId: probeKey.panelId,
                branch: nextBranch,
                isDirty: isDirty
            )
            if !isDirty {
                if let indexSignature = snapshot.indexSignature {
                    workspaceGitCleanIndexSignatureByKey[probeKey] = indexSignature
                } else {
                    workspaceGitCleanIndexSignatureByKey.removeValue(forKey: probeKey)
                }
                if let indexContentSignature = snapshot.indexContentSignature {
                    workspaceGitCleanIndexContentSignatureByKey[probeKey] = indexContentSignature
                } else {
                    workspaceGitCleanIndexContentSignatureByKey.removeValue(forKey: probeKey)
                }
            }
        } else {
            workspaceGitCleanIndexSignatureByKey.removeValue(forKey: probeKey)
            workspaceGitCleanIndexContentSignatureByKey.removeValue(forKey: probeKey)
            workspaceGitHeadSignatureByKey.removeValue(forKey: probeKey)
            workspace.clearPanelGitBranch(panelId: probeKey.panelId)
        }

        switch snapshot.pullRequest {
        case .resolved(let pullRequest):
            workspace.updatePanelPullRequest(
                panelId: probeKey.panelId,
                number: pullRequest.number,
                label: pullRequest.label,
                url: pullRequest.url,
                status: pullRequest.status,
                branch: pullRequest.branch,
                isStale: false
            )
        case .notFound:
            if workspace.panelPullRequests[probeKey.panelId] != nil {
                workspace.clearPanelPullRequest(panelId: probeKey.panelId)
            }
        case .deferred, .unsupportedRepository, .transientFailure:
            break
        }

        if snapshot.branch != nil {
            scheduleWorkspacePullRequestRefresh(
                workspaceId: probeKey.workspaceId,
                panelId: probeKey.panelId,
                reason: "localGitProbe"
            )
        }

#if DEBUG
        let branchLabel = snapshot.branch ?? "none"
        let prLabel: String = {
            switch snapshot.pullRequest {
            case .deferred:
                return "deferred"
            case .unsupportedRepository:
                return "unsupported"
            case .notFound:
                return "none"
            case .transientFailure:
                return "transientFailure"
            case .resolved(let pullRequest):
                return "#\(pullRequest.number):\(pullRequest.status.rawValue)"
            }
        }()
        cmuxDebugLog(
            "workspace.gitProbe.apply workspace=\(probeKey.workspaceId.uuidString.prefix(5)) " +
            "panel=\(probeKey.panelId.uuidString.prefix(5)) branch=\(branchLabel) dirty=\(snapshot.isDirty ? 1 : 0) " +
            "pr=\(prLabel)"
        )
#endif
    }

    private func shouldStopWorkspaceGitMetadataRefresh(
        _ snapshot: InitialWorkspaceGitMetadataSnapshot
    ) -> Bool {
        if snapshot.isRepository {
            return false
        }
        switch snapshot.pullRequest {
        case .deferred, .transientFailure:
            return false
        case .unsupportedRepository, .notFound, .resolved:
            return true
        }
    }

    private nonisolated static func initialWorkspaceGitMetadataSnapshot(
        for directory: String
    ) async -> InitialWorkspaceGitMetadataSnapshot {
        guard let repository = resolveGitRepository(containing: directory) else {
            return InitialWorkspaceGitMetadataSnapshot(
                isRepository: false,
                branch: nil,
                isDirty: false,
                indexSignature: nil,
                indexContentSignature: nil,
                headSignature: nil,
                pullRequest: .notFound
            )
        }
        let trackedChanges = gitTrackedChangesSnapshot(repository: repository)
        let headSignature = gitHeadSignature(repository: repository)

        let branch = normalizedBranchName(gitBranchName(repository: repository))
        guard let branch else {
            return InitialWorkspaceGitMetadataSnapshot(
                isRepository: true,
                branch: nil,
                isDirty: trackedChanges.isDirty,
                indexSignature: trackedChanges.indexSignature,
                indexContentSignature: trackedChanges.indexContentSignature,
                headSignature: headSignature,
                pullRequest: .notFound
            )
        }

        return InitialWorkspaceGitMetadataSnapshot(
            isRepository: true,
            branch: branch,
            isDirty: trackedChanges.isDirty,
            indexSignature: trackedChanges.indexSignature,
            indexContentSignature: trackedChanges.indexContentSignature,
            headSignature: headSignature,
            pullRequest: .deferred
        )
    }

    private nonisolated static func resolveGitRepository(containing directory: String) -> ResolvedGitRepository? {
        let startURL = URL(fileURLWithPath: directory).standardizedFileURL
        let fileManager = FileManager.default
        var currentURL = startURL
        var isDirectory: ObjCBool = false

        if !fileManager.fileExists(atPath: currentURL.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            currentURL.deleteLastPathComponent()
        }

        while true {
            let dotGitURL = currentURL.appendingPathComponent(".git")
            if fileManager.fileExists(atPath: dotGitURL.path, isDirectory: &isDirectory) {
                let gitDirectory: String?
                if isDirectory.boolValue {
                    gitDirectory = dotGitURL.standardizedFileURL.path
                } else {
                    gitDirectory = gitDirectoryFromDotGitFile(dotGitURL, relativeTo: currentURL)
                }

                if let gitDirectory {
                    let commonDirectory = gitCommonDirectory(gitDirectory: gitDirectory)
                    return ResolvedGitRepository(
                        workTreeRoot: currentURL.standardizedFileURL.path,
                        gitDirectory: gitDirectory,
                        commonDirectory: commonDirectory
                    )
                }
            }

            let parentURL = currentURL.deletingLastPathComponent()
            if Self.shouldStopGitRepositorySearch(currentURL: currentURL, parentURL: parentURL) {
                return nil
            }
            currentURL = parentURL
        }
    }

    nonisolated static func shouldStopGitRepositorySearch(currentURL: URL, parentURL: URL) -> Bool {
        if parentURL.path == currentURL.path {
            return true
        }

        let standardizedCurrentPath = currentURL.standardizedFileURL.path
        if standardizedCurrentPath == "/" {
            return true
        }

        return parentURL.standardizedFileURL.path == standardizedCurrentPath
    }

    private nonisolated static func gitDirectoryFromDotGitFile(
        _ dotGitURL: URL,
        relativeTo workTreeRootURL: URL
    ) -> String? {
        guard let contents = try? String(contentsOf: dotGitURL, encoding: .utf8) else {
            return nil
        }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "gitdir:"
        guard trimmed.lowercased().hasPrefix(prefix) else {
            return nil
        }

        let rawPath = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else { return nil }
        if rawPath.hasPrefix("/") {
            return URL(fileURLWithPath: String(rawPath)).standardizedFileURL.path
        }
        return workTreeRootURL
            .appendingPathComponent(String(rawPath))
            .standardizedFileURL
            .path
    }

    private nonisolated static func gitCommonDirectory(gitDirectory: String) -> String {
        let gitDirectoryURL = URL(fileURLWithPath: gitDirectory)
        let commonDirURL = gitDirectoryURL.appendingPathComponent("commondir")
        guard let contents = try? String(contentsOf: commonDirURL, encoding: .utf8) else {
            return gitDirectory
        }

        let rawPath = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else { return gitDirectory }
        if rawPath.hasPrefix("/") {
            return URL(fileURLWithPath: rawPath).standardizedFileURL.path
        }
        return gitDirectoryURL
            .appendingPathComponent(rawPath)
            .standardizedFileURL
            .path
    }

    private nonisolated static func workspaceGitMetadataWatcherDescriptor(
        for directory: String
    ) -> WorkspaceGitMetadataWatcher.Descriptor? {
        guard let repository = resolveGitRepository(containing: directory) else {
            return nil
        }

        let candidatePaths = [
            repository.workTreeRoot,
        ] + gitRepositoryMetadataWatchPaths(repository: repository)
            + gitlinkMetadataWatchPaths(repository: repository)
        var watchedPaths: [String] = []
        var seen: Set<String> = []
        for path in candidatePaths {
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            guard seen.insert(normalized).inserted else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: normalized, isDirectory: &isDirectory) else {
                continue
            }
            watchedPaths.append(normalized)
        }

        return WorkspaceGitMetadataWatcher.Descriptor(
            directory: repository.workTreeRoot,
            watchedPaths: watchedPaths.sorted()
        )
    }

    private nonisolated static func gitRepositoryMetadataWatchPaths(
        repository: ResolvedGitRepository
    ) -> [String] {
        [
            URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("HEAD").path,
            URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("index").path,
            URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("refs").path,
            URL(fileURLWithPath: repository.commonDirectory).appendingPathComponent("refs").path,
            URL(fileURLWithPath: repository.commonDirectory).appendingPathComponent("packed-refs").path,
        ] + gitConfigURLs(repository: repository).map(\.path)
    }

    private nonisolated static func gitlinkMetadataWatchPaths(
        repository: ResolvedGitRepository
    ) -> [String] {
        let indexURL = URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("index")
        guard let indexSnapshot = gitIndexSnapshot(indexURL: indexURL) else {
            return []
        }

        let gitlinkMode: UInt32 = 0o160000
        var paths: [String] = []
        for entry in indexSnapshot.entries where (entry.mode & 0o170000) == gitlinkMode {
            let gitlinkURL = URL(fileURLWithPath: repository.workTreeRoot)
                .appendingPathComponent(entry.path)
                .standardizedFileURL
            guard let submoduleRepository = resolveGitRepository(containing: gitlinkURL.path),
                  submoduleRepository.workTreeRoot == gitlinkURL.path else {
                continue
            }
            paths.append(contentsOf: gitRepositoryMetadataWatchPaths(repository: submoduleRepository))
        }
        return paths
    }

    private nonisolated static func gitBranchName(repository: ResolvedGitRepository) -> String? {
        let headURL = URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("HEAD")
        guard let contents = try? String(contentsOf: headURL, encoding: .utf8) else {
            return nil
        }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        let branchPrefix = "ref: refs/heads/"
        guard trimmed.hasPrefix(branchPrefix) else {
            return nil
        }
        let branch = String(trimmed.dropFirst(branchPrefix.count))
        return branch.isEmpty ? nil : branch
    }

    private nonisolated static func gitHeadSignature(repository: ResolvedGitRepository) -> String? {
        let headURL = URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("HEAD")
        guard let contents = try? String(contentsOf: headURL, encoding: .utf8) else {
            return nil
        }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        let refPrefix = "ref: "
        guard trimmed.hasPrefix(refPrefix) else {
            return trimmed.isEmpty ? nil : trimmed
        }

        let refName = String(trimmed.dropFirst(refPrefix.count))
        guard !refName.isEmpty else { return trimmed }
        let refValue = gitRefValue(repository: repository, refName: refName) ?? ""
        return "\(trimmed)\n\(refValue)"
    }

    private nonisolated static func gitRefValue(repository: ResolvedGitRepository, refName: String) -> String? {
        let refURLs = [
            URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent(refName),
            URL(fileURLWithPath: repository.commonDirectory).appendingPathComponent(refName),
        ]
        var seenPaths: Set<String> = []
        for refURL in refURLs {
            let path = refURL.standardizedFileURL.path
            guard seenPaths.insert(path).inserted,
                  let contents = try? String(contentsOf: refURL, encoding: .utf8) else {
                continue
            }
            let value = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }

        let packedRefsURL = URL(fileURLWithPath: repository.commonDirectory).appendingPathComponent("packed-refs")
        guard let packedRefs = try? String(contentsOf: packedRefsURL, encoding: .utf8) else {
            return nil
        }
        for rawLine in packedRefs.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("^") else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2, String(parts[1]) == refName else { continue }
            return String(parts[0])
        }
        return nil
    }

    private nonisolated static func gitRemoteVOutput(repository: ResolvedGitRepository) -> String? {
        var lines: [String] = []
        var seenConfigPaths: Set<String> = []
        for configURL in gitRootConfigURLs(repository: repository) {
            appendGitRemoteVLines(
                fromConfigURL: configURL,
                repository: repository,
                seenConfigPaths: &seenConfigPaths,
                lines: &lines
            )
        }
        return lines.isEmpty ? nil : lines.joined()
    }

    private nonisolated static func gitRootConfigURLs(repository: ResolvedGitRepository) -> [URL] {
        [
            URL(fileURLWithPath: repository.commonDirectory).appendingPathComponent("config"),
            URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("config"),
        ]
    }

    private nonisolated static func gitConfigURLs(repository: ResolvedGitRepository) -> [URL] {
        var urls: [URL] = []
        var pendingURLs = gitRootConfigURLs(repository: repository)
        var seenConfigPaths: Set<String> = []

        while !pendingURLs.isEmpty {
            let configURL = pendingURLs.removeFirst().standardizedFileURL
            let path = configURL.path
            guard seenConfigPaths.insert(path).inserted else { continue }
            urls.append(configURL)
            guard let config = try? String(contentsOf: configURL, encoding: .utf8) else {
                continue
            }
            pendingURLs.append(
                contentsOf: gitIncludedConfigURLs(
                    fromConfig: config,
                    configURL: configURL,
                    repository: repository
                )
            )
        }

        return urls
    }

    private nonisolated static func gitRemoteVLines(fromConfig config: String) -> [String] {
        var currentRemoteName: String?
        var lines: [String] = []

        for rawLine in config.components(separatedBy: .newlines) {
            let line = gitConfigLineRemovingInlineComment(rawLine)
                .trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                currentRemoteName = gitConfigRemoteName(fromSectionHeader: line)
                continue
            }

            guard let currentRemoteName else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2, parts[0] == "url" else {
                continue
            }
            let remoteURL = gitConfigUnquotedValue(parts[1])
            guard !remoteURL.isEmpty else {
                continue
            }
            lines.append("\(currentRemoteName)\t\(remoteURL) (fetch)\n")
        }

        return lines
    }

    private nonisolated static func appendGitRemoteVLines(
        fromConfigURL configURL: URL,
        repository: ResolvedGitRepository,
        seenConfigPaths: inout Set<String>,
        lines: inout [String]
    ) {
        let configURL = configURL.standardizedFileURL
        guard seenConfigPaths.insert(configURL.path).inserted,
              let config = try? String(contentsOf: configURL, encoding: .utf8) else {
            return
        }

        var currentRemoteName: String?
        var currentSectionAllowsIncludePath = false

        for rawLine in config.components(separatedBy: .newlines) {
            let line = gitConfigLineRemovingInlineComment(rawLine)
                .trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                currentRemoteName = gitConfigRemoteName(fromSectionHeader: line)
                if line == "[include]" {
                    currentSectionAllowsIncludePath = true
                } else if let condition = gitConfigIncludeIfCondition(fromSectionHeader: line) {
                    currentSectionAllowsIncludePath = gitConfigIncludeIfConditionMatches(
                        condition,
                        repository: repository
                    )
                } else {
                    currentSectionAllowsIncludePath = false
                }
                continue
            }

            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }

            if let currentRemoteName,
               parts.count == 2,
               parts[0] == "url" {
                let remoteURL = gitConfigUnquotedValue(parts[1])
                guard !remoteURL.isEmpty else {
                    continue
                }
                lines.append("\(currentRemoteName)\t\(remoteURL) (fetch)\n")
                continue
            }

            guard currentSectionAllowsIncludePath,
                  parts.count == 2,
                  parts[0] == "path",
                  let includeURL = gitConfigIncludeURL(
                      fromPathValue: parts[1],
                      relativeTo: configURL
                  ) else {
                continue
            }
            appendGitRemoteVLines(
                fromConfigURL: includeURL,
                repository: repository,
                seenConfigPaths: &seenConfigPaths,
                lines: &lines
            )
        }
    }

    private nonisolated static func gitIncludedConfigURLs(
        fromConfig config: String,
        configURL: URL,
        repository: ResolvedGitRepository
    ) -> [URL] {
        var currentSectionAllowsPath = false
        var urls: [URL] = []

        for rawLine in config.components(separatedBy: .newlines) {
            let line = gitConfigLineRemovingInlineComment(rawLine)
                .trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                if line == "[include]" {
                    currentSectionAllowsPath = true
                } else if let condition = gitConfigIncludeIfCondition(fromSectionHeader: line) {
                    currentSectionAllowsPath = gitConfigIncludeIfConditionMatches(
                        condition,
                        repository: repository
                    )
                } else {
                    currentSectionAllowsPath = false
                }
                continue
            }

            guard currentSectionAllowsPath else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2,
                  parts[0].lowercased() == "path",
                  let includeURL = gitConfigIncludeURL(
                    fromPathValue: parts[1],
                    relativeTo: configURL
                  ) else {
                continue
            }
            urls.append(includeURL)
        }

        return urls
    }

    private nonisolated static func gitConfigUnquotedValue(_ value: String) -> String {
        let trimmedValue = value.trimmingCharacters(in: .whitespaces)
        guard trimmedValue.first == "\"",
              trimmedValue.last == "\"",
              trimmedValue.count >= 2 else {
            return trimmedValue
        }

        var result = ""
        var isEscaped = false
        for character in trimmedValue.dropFirst().dropLast() {
            if isEscaped {
                result.append(character)
                isEscaped = false
                continue
            }

            if character == "\\" {
                isEscaped = true
                continue
            }

            result.append(character)
        }

        if isEscaped {
            result.append("\\")
        }
        return result
    }

    private nonisolated static func gitConfigLineRemovingInlineComment(_ line: String) -> String {
        var result = ""
        var isInsideDoubleQuotedString = false
        var isEscaped = false
        var previousWasWhitespace = true

        for character in line {
            if isEscaped {
                result.append(character)
                isEscaped = false
                previousWasWhitespace = character.isWhitespace
                continue
            }

            if isInsideDoubleQuotedString && character == "\\" {
                result.append(character)
                isEscaped = true
                previousWasWhitespace = false
                continue
            }

            if character == "\"" {
                result.append(character)
                isInsideDoubleQuotedString.toggle()
                previousWasWhitespace = false
                continue
            }

            if !isInsideDoubleQuotedString,
               previousWasWhitespace,
               (character == "#" || character == ";") {
                break
            }

            result.append(character)
            previousWasWhitespace = character.isWhitespace
        }

        return result
    }

    private nonisolated static func gitConfigRemoteName(fromSectionHeader header: String) -> String? {
        let prefix = "[remote \""
        let suffix = "\"]"
        guard header.hasPrefix(prefix), header.hasSuffix(suffix) else {
            return nil
        }
        let name = header.dropFirst(prefix.count).dropLast(suffix.count)
        return name.isEmpty ? nil : String(name)
    }

    private nonisolated static func gitConfigIncludeIfCondition(fromSectionHeader header: String) -> String? {
        let prefix = "[includeIf \""
        let suffix = "\"]"
        guard header.hasPrefix(prefix), header.hasSuffix(suffix) else {
            return nil
        }
        let condition = header.dropFirst(prefix.count).dropLast(suffix.count)
        return condition.isEmpty ? nil : String(condition)
    }

    private nonisolated static func gitConfigIncludeURL(
        fromPathValue pathValue: String,
        relativeTo configURL: URL
    ) -> URL? {
        let path = gitConfigUnquotedValue(pathValue)
        guard !path.isEmpty else { return nil }
        if path == "~" {
            return FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        }
        if path.hasPrefix("~/") {
            let relativePath = String(path.dropFirst(2))
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(relativePath)
                .standardizedFileURL
        }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return configURL
            .deletingLastPathComponent()
            .appendingPathComponent(path)
            .standardizedFileURL
    }

    private nonisolated static func gitConfigIncludeIfConditionMatches(
        _ condition: String,
        repository: ResolvedGitRepository
    ) -> Bool {
        let lowercasedCondition = condition.lowercased()
        if lowercasedCondition.hasPrefix("gitdir/i:") {
            let pattern = String(condition.dropFirst("gitdir/i:".count))
            return gitConfigGitdirPatternMatches(pattern, repository: repository, caseInsensitive: true)
        }
        if lowercasedCondition.hasPrefix("gitdir:") {
            let pattern = String(condition.dropFirst("gitdir:".count))
            return gitConfigGitdirPatternMatches(pattern, repository: repository, caseInsensitive: false)
        }
        if lowercasedCondition.hasPrefix("onbranch:") {
            let pattern = String(condition.dropFirst("onbranch:".count))
            guard let branch = gitBranchName(repository: repository) else { return false }
            return gitConfigGlobMatches(branch, pattern: pattern, caseInsensitive: false)
        }
        return false
    }

    private nonisolated static func gitConfigGitdirPatternMatches(
        _ pattern: String,
        repository: ResolvedGitRepository,
        caseInsensitive: Bool
    ) -> Bool {
        let isRecursiveDirectoryPattern = pattern.hasSuffix("/")
        var expandedPattern = gitConfigExpandedPattern(pattern)
        if isRecursiveDirectoryPattern, !expandedPattern.hasSuffix("/") {
            expandedPattern.append("/")
        }
        if isRecursiveDirectoryPattern {
            expandedPattern.append("**")
        }
        let candidates = [
            repository.gitDirectory,
            repository.commonDirectory,
            repository.workTreeRoot,
        ].map { URL(fileURLWithPath: $0).standardizedFileURL.path }

        for candidate in candidates {
            if gitConfigGlobMatches(candidate, pattern: expandedPattern, caseInsensitive: caseInsensitive) ||
                gitConfigGlobMatches(candidate + "/", pattern: expandedPattern, caseInsensitive: caseInsensitive) {
                return true
            }
        }
        return false
    }

    private nonisolated static func gitConfigExpandedPattern(_ pattern: String) -> String {
        if pattern == "~" {
            return FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        }
        if pattern.hasPrefix("~/") {
            let relativePath = String(pattern.dropFirst(2))
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(relativePath)
                .standardizedFileURL
                .path
        }
        return URL(fileURLWithPath: pattern).standardizedFileURL.path
    }

    private nonisolated static func gitConfigGlobMatches(
        _ value: String,
        pattern: String,
        caseInsensitive: Bool
    ) -> Bool {
        let candidateValue = caseInsensitive ? value.lowercased() : value
        let candidatePattern = caseInsensitive ? pattern.lowercased() : pattern
        guard let regex = try? NSRegularExpression(
            pattern: gitConfigGlobRegexPattern(candidatePattern)
        ) else {
            return fnmatch(candidatePattern, candidateValue, 0) == 0
        }
        let range = NSRange(candidateValue.startIndex..<candidateValue.endIndex, in: candidateValue)
        return regex.firstMatch(in: candidateValue, range: range) != nil
    }

    private nonisolated static func gitConfigGlobRegexPattern(_ pattern: String) -> String {
        let characters = Array(pattern)
        var regex = "^"
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if character == "*" {
                var starCount = 1
                while index + starCount < characters.count,
                      characters[index + starCount] == "*" {
                    starCount += 1
                }
                index += starCount

                if starCount >= 2 {
                    if index < characters.count, characters[index] == "/" {
                        index += 1
                        regex += "(?:.*/)?"
                    } else {
                        regex += ".*"
                    }
                } else {
                    regex += "[^/]*"
                }
                continue
            }

            if character == "?" {
                regex += "[^/]"
                index += 1
                continue
            }

            if character == "[" {
                let parsedClass = gitConfigGlobCharacterClass(characters, startIndex: index)
                if let parsedClass {
                    regex += parsedClass.regex
                    index = parsedClass.endIndex
                    continue
                }
            }

            regex += NSRegularExpression.escapedPattern(for: String(character))
            index += 1
        }

        regex += "$"
        return regex
    }

    private nonisolated static func gitConfigGlobCharacterClass(
        _ characters: [Character],
        startIndex: Int
    ) -> (regex: String, endIndex: Int)? {
        guard startIndex < characters.count, characters[startIndex] == "[" else {
            return nil
        }

        var index = startIndex + 1
        guard index < characters.count else { return nil }

        var regex = "["
        if characters[index] == "!" {
            regex += "^"
            index += 1
        } else if characters[index] == "^" {
            regex += "\\^"
            index += 1
        }

        if index < characters.count, characters[index] == "]" {
            regex += "\\]"
            index += 1
        }

        var hasTerminator = false
        while index < characters.count {
            let character = characters[index]
            if character == "]" {
                hasTerminator = true
                index += 1
                break
            }
            switch character {
            case "\\":
                regex += "\\\\"
            case "[":
                regex += "\\["
            default:
                regex += String(character)
            }
            index += 1
        }

        guard hasTerminator else { return nil }
        regex += "]"
        return (regex, index)
    }

    private nonisolated static func gitTrackedChangesSnapshot(
        repository: ResolvedGitRepository
    ) -> (isDirty: Bool, indexSignature: String?, indexContentSignature: String?) {
        let indexURL = URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("index")
        guard let indexSnapshot = gitIndexSnapshot(indexURL: indexURL) else {
            return (false, gitIndexFileSignature(indexURL: indexURL), nil)
        }

        for entry in indexSnapshot.entries {
            let fileURL = URL(fileURLWithPath: repository.workTreeRoot).appendingPathComponent(entry.path)
            let gitlinkMode: UInt32 = 0o160000
            if (entry.mode & 0o170000) == gitlinkMode {
                guard let submoduleCommit = gitlinkWorktreeCommit(
                    parentRepository: repository,
                    gitlinkPath: entry.path
                ) else {
                    return (true, indexSnapshot.signature, indexSnapshot.contentSignature)
                }
                if submoduleCommit.caseInsensitiveCompare(entry.objectID) != .orderedSame {
                    return (true, indexSnapshot.signature, indexSnapshot.contentSignature)
                }
                continue
            }

            var statValue = stat()
            guard lstat(fileURL.path, &statValue) == 0 else {
                return (true, indexSnapshot.signature, indexSnapshot.contentSignature)
            }
            let size = gitIndexUInt32Field(statValue.st_size)
            let mtimeSeconds = gitIndexUInt32Field(statValue.st_mtimespec.tv_sec)
            let mtimeNanoseconds = gitIndexUInt32Field(statValue.st_mtimespec.tv_nsec)
            guard let mode = gitIndexComparableMode(for: statValue.st_mode) else {
                return (true, indexSnapshot.signature, indexSnapshot.contentSignature)
            }
            if size != entry.size ||
                mode != entry.mode ||
                mtimeSeconds != entry.mtimeSeconds ||
                mtimeNanoseconds != entry.mtimeNanoseconds {
                return (true, indexSnapshot.signature, indexSnapshot.contentSignature)
            }
        }

        return (false, indexSnapshot.signature, indexSnapshot.contentSignature)
    }

    private nonisolated static func gitIndexSnapshot(indexURL: URL) -> GitIndexSnapshot? {
        guard let data = try? Data(contentsOf: indexURL), data.count >= 32 else {
            return nil
        }
        let bytes = [UInt8](data)
        guard bytes[0] == 0x44, bytes[1] == 0x49, bytes[2] == 0x52, bytes[3] == 0x43 else {
            return nil
        }
        let version = readBigEndianUInt32(bytes, at: 4)
        guard version == 2 || version == 3 || version == 4 else {
            return nil
        }
        let entryCount = Int(readBigEndianUInt32(bytes, at: 8))
        let contentEnd = bytes.count - 20
        var offset = 12
        var entries: [GitIndexEntryStat] = []
        var contentEntries: [GitIndexEntryStat] = []
        entries.reserveCapacity(min(entryCount, 1024))
        contentEntries.reserveCapacity(min(entryCount, 1024))
        var previousPathBytes: [UInt8] = []

        for _ in 0..<entryCount {
            guard offset + 62 <= contentEnd else { return nil }
            let entryStart = offset
            let mtimeSeconds = readBigEndianUInt32(bytes, at: offset + 8)
            let mtimeNanoseconds = readBigEndianUInt32(bytes, at: offset + 12)
            let mode = readBigEndianUInt32(bytes, at: offset + 24)
            let size = readBigEndianUInt32(bytes, at: offset + 36)
            let objectID = bytes[(offset + 40)..<(offset + 60)].map {
                String(format: "%02x", $0)
            }.joined()
            let flags = readBigEndianUInt16(bytes, at: offset + 60)
            let pathLength = Int(flags & 0x0fff)
            let hasExtendedFlags = version >= 3 && (flags & 0x4000) != 0
            var extendedFlags: UInt16 = 0
            offset += 62
            if hasExtendedFlags {
                guard offset + 2 <= contentEnd else { return nil }
                extendedFlags = readBigEndianUInt16(bytes, at: offset)
                offset += 2
            }

            let pathBytes: [UInt8]
            if version == 4 {
                guard let stripLength = readGitIndexV4PathStripLength(bytes, offset: &offset),
                      stripLength <= previousPathBytes.count else {
                    return nil
                }
                let suffixStart = offset
                while offset < contentEnd, bytes[offset] != 0 {
                    offset += 1
                }
                guard offset < contentEnd else { return nil }
                pathBytes = Array(previousPathBytes.dropLast(stripLength)) + Array(bytes[suffixStart..<offset])
            } else {
                let pathStart = offset
                if pathLength < 0x0fff {
                    offset += pathLength
                    guard offset < contentEnd else { return nil }
                } else {
                    while offset < contentEnd, bytes[offset] != 0 {
                        offset += 1
                    }
                    guard offset < contentEnd else { return nil }
                }
                pathBytes = Array(bytes[pathStart..<offset])
            }

            let pathData = Data(pathBytes)
            guard let path = String(data: pathData, encoding: .utf8), !path.isEmpty else {
                return nil
            }
            previousPathBytes = pathBytes
            let entryStat = GitIndexEntryStat(
                path: path,
                mode: mode,
                objectID: objectID,
                mtimeSeconds: mtimeSeconds,
                mtimeNanoseconds: mtimeNanoseconds,
                size: size
            )
            contentEntries.append(entryStat)

            let assumeUnchangedFlag: UInt16 = 0x8000
            let skipWorktreeExtendedFlag: UInt16 = 0x4000
            if (flags & assumeUnchangedFlag) == 0,
               (extendedFlags & skipWorktreeExtendedFlag) == 0 {
                entries.append(entryStat)
            }

            offset += 1
            if version != 4 {
                let entryLength = offset - entryStart
                let padding = (8 - (entryLength % 8)) % 8
                offset += padding
            }
        }

        let checksum = bytes[(bytes.count - 20)..<bytes.count].map { String(format: "%02x", $0) }.joined()
        return GitIndexSnapshot(
            entries: entries,
            signature: checksum,
            contentSignature: gitIndexContentSignature(entries: contentEntries)
        )
    }

    private nonisolated static func gitIndexContentSignature(entries: [GitIndexEntryStat]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037

        func appendByte(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }

        func appendUInt32(_ value: UInt32) {
            appendByte(UInt8((value >> 24) & 0xff))
            appendByte(UInt8((value >> 16) & 0xff))
            appendByte(UInt8((value >> 8) & 0xff))
            appendByte(UInt8(value & 0xff))
        }

        func appendString(_ value: String) {
            for byte in value.utf8 {
                appendByte(byte)
            }
        }

        appendUInt32(UInt32(truncatingIfNeeded: entries.count))
        for entry in entries {
            appendString(entry.path)
            appendByte(0)
            appendUInt32(entry.mode)
            appendByte(0)
            appendString(entry.objectID)
            appendByte(0)
        }
        return String(format: "%016llx", CUnsignedLongLong(hash))
    }

    private nonisolated static func gitlinkWorktreeCommit(
        parentRepository: ResolvedGitRepository,
        gitlinkPath: String
    ) -> String? {
        let gitlinkURL = URL(fileURLWithPath: parentRepository.workTreeRoot)
            .appendingPathComponent(gitlinkPath)
            .standardizedFileURL
        guard let submoduleRepository = resolveGitRepository(containing: gitlinkURL.path),
              submoduleRepository.workTreeRoot == gitlinkURL.path else {
            return nil
        }
        return gitCurrentCommit(repository: submoduleRepository)
    }

    private nonisolated static func gitCurrentCommit(repository: ResolvedGitRepository) -> String? {
        let headURL = URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("HEAD")
        guard let contents = try? String(contentsOf: headURL, encoding: .utf8) else {
            return nil
        }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        let refPrefix = "ref: "
        let value: String
        if trimmed.hasPrefix(refPrefix) {
            let refName = String(trimmed.dropFirst(refPrefix.count))
            guard !refName.isEmpty, let refValue = gitRefValue(repository: repository, refName: refName) else {
                return nil
            }
            value = refValue
        } else {
            value = trimmed
        }

        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count == 40,
              normalized.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        return normalized
    }

    private nonisolated static func gitIndexComparableMode(for statMode: mode_t) -> UInt32? {
        let type = statMode & mode_t(S_IFMT)
        switch type {
        case mode_t(S_IFREG):
            return (statMode & 0o111) == 0 ? 0o100644 : 0o100755
        case mode_t(S_IFLNK):
            return 0o120000
        default:
            return nil
        }
    }

    private nonisolated static func gitIndexUInt32Field<T: BinaryInteger>(_ value: T) -> UInt32 {
        UInt32(truncatingIfNeeded: UInt64(truncatingIfNeeded: value))
    }

    private nonisolated static func gitIndexFileSignature(indexURL: URL) -> String? {
        guard let data = try? Data(contentsOf: indexURL), data.count >= 20 else {
            return nil
        }
        return data.suffix(20).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func readGitIndexV4PathStripLength(
        _ bytes: [UInt8],
        offset: inout Int
    ) -> Int? {
        guard offset < bytes.count else { return nil }
        var byte = bytes[offset]
        offset += 1
        var value = Int(byte & 0x7f)
        while (byte & 0x80) != 0 {
            guard offset < bytes.count else { return nil }
            // Git's index v4 path compression uses varint.c's encode/decode pair.
            // Continuation bytes increment the accumulated value before shifting.
            value += 1
            byte = bytes[offset]
            offset += 1
            value = (value << 7) + Int(byte & 0x7f)
        }
        return value
    }

    private nonisolated static func readBigEndianUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private nonisolated static func readBigEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24) |
            (UInt32(bytes[offset + 1]) << 16) |
            (UInt32(bytes[offset + 2]) << 8) |
            UInt32(bytes[offset + 3])
    }

    private nonisolated static func fetchWorkspacePullRequestRepoResults(
        repoDirectoriesBySlug: [String: String],
        candidateBranchesByRepo: [String: Set<String>],
        cacheBySlug: [String: WorkspacePullRequestRepoCacheEntry],
        now: Date,
        allowCachedResults: Bool
    ) async -> [String: WorkspacePullRequestRepoFetchResult] {
        guard !repoDirectoriesBySlug.isEmpty else { return [:] }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = max(Self.workspacePullRequestProbeTimeout, 8)
        configuration.timeoutIntervalForResource = max(Self.workspacePullRequestProbeTimeout, 8)
        let session = URLSession(configuration: configuration)
        let authHeader = await workspacePullRequestAuthHeaderValue()
        var results: [String: WorkspacePullRequestRepoFetchResult] = [:]

        let fetchedResults = await withTaskGroup(
            of: (String, WorkspacePullRequestRepoFetchResult).self,
            returning: [(String, WorkspacePullRequestRepoFetchResult)].self
        ) { group in
            for repoSlug in repoDirectoriesBySlug.keys {
                group.addTask {
                    let result = await Self.workspacePullRequestRepoFetchResult(
                        repoSlug: repoSlug,
                        candidateBranches: candidateBranchesByRepo[repoSlug] ?? [],
                        cachedEntry: cacheBySlug[repoSlug],
                        useCachedRecentWindow: allowCachedResults
                            && (cacheBySlug[repoSlug].map {
                                now.timeIntervalSince($0.fetchedAt) < Self.workspacePullRequestRepoCacheLifetime
                            } ?? false),
                        session: session,
                        authHeader: authHeader
                    )
                    return (repoSlug, result)
                }
            }

            var collected: [(String, WorkspacePullRequestRepoFetchResult)] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        for (repoSlug, result) in fetchedResults {
            results[repoSlug] = result
        }
        return results
    }

    private nonisolated static func resolveWorkspacePullRequestRefreshResults(
        candidates: [WorkspacePullRequestCandidate],
        repoResults: [String: WorkspacePullRequestRepoFetchResult]
    ) -> [WorkspacePullRequestRefreshResult] {
        candidates.map { candidate in
            if candidate.repoSlugs.isEmpty {
                return WorkspacePullRequestRefreshResult(
                    workspaceId: candidate.workspaceId,
                    panelId: candidate.panelId,
                    resolution: .unsupportedRepository,
                    usedCachedRepoData: false
                )
            }

            var matchedPullRequest: GitHubPullRequestProbeItem?
            var matchedPullRequestUsedCache = false
            var sawTransientFailure = false
            var sawCachedSuccess = false

            for repoSlug in candidate.repoSlugs {
                guard let repoResult = repoResults[repoSlug] else { continue }
                switch repoResult {
                case .success(let cacheEntry, let usedCache, let transientBranches):
                    if usedCache {
                        sawCachedSuccess = true
                    }
                    if let candidateMatch = cacheEntry.pullRequestsByBranch[candidate.branch] {
                        matchedPullRequest = candidateMatch
                        matchedPullRequestUsedCache = usedCache
                        break
                    }
                    if transientBranches.contains(candidate.branch) {
                        sawTransientFailure = true
                    }
                case .transientFailure:
                    sawTransientFailure = true
                }
            }

            let resolution: WorkspacePullRequestRefreshResult.Resolution
            let usedCachedRepoData: Bool
            if let matchedPullRequest,
               let status = pullRequestStatus(from: matchedPullRequest.state) {
                resolution = .resolved(
                    WorkspacePullRequestResolvedItem(
                        number: matchedPullRequest.number,
                        urlString: matchedPullRequest.url,
                        statusRawValue: status.rawValue,
                        branch: candidate.branch
                    )
                )
                usedCachedRepoData = matchedPullRequestUsedCache
            } else if sawTransientFailure {
                resolution = .transientFailure
                usedCachedRepoData = false
            } else {
                resolution = .notFound
                usedCachedRepoData = sawCachedSuccess
            }

            return WorkspacePullRequestRefreshResult(
                workspaceId: candidate.workspaceId,
                panelId: candidate.panelId,
                resolution: resolution,
                usedCachedRepoData: usedCachedRepoData
            )
        }
    }

    private nonisolated static func workspacePullRequestRepoFetchResult(
        repoSlug: String,
        candidateBranches: Set<String>,
        cachedEntry: WorkspacePullRequestRepoCacheEntry?,
        useCachedRecentWindow: Bool,
        session: URLSession,
        authHeader: String?
    ) async -> WorkspacePullRequestRepoFetchResult {
        let normalizedCandidateBranches = Set(candidateBranches.compactMap(normalizedBranchName))

        if useCachedRecentWindow,
           let cachedEntry {
            let unresolvedBranches = unresolvedWorkspacePullRequestBranches(
                normalizedCandidateBranches,
                in: cachedEntry
            )
            if unresolvedBranches.isEmpty {
#if DEBUG
                cmuxDebugLog(
                    "workspace.prRefresh.repo.cache repo=\(repoSlug) " +
                    "branches=\(cachedEntry.pullRequestsByBranch.count)"
                )
#endif
                return .success(cachedEntry, usedCache: true, transientBranches: [])
            }

            let lookupOutcome = await workspacePullRequestBranchLookupOutcome(
                repoSlug: repoSlug,
                candidateBranches: unresolvedBranches,
                baseEntry: cachedEntry,
                refreshedAt: Date(),
                session: session,
                authHeader: authHeader
            )
#if DEBUG
            cmuxDebugLog(
                "workspace.prRefresh.repo.cache.miss repo=\(repoSlug) " +
                "branchLookups=\(unresolvedBranches.count) transient=\(lookupOutcome.transientBranches.count)"
            )
#endif
            return .success(
                lookupOutcome.cacheEntry,
                usedCache: false,
                transientBranches: lookupOutcome.transientBranches
            )
        }

        let fetchTimestamp = Date()
        var page = 1
        var fetchedPageCount = 0
        var allPullRequests: [GitHubPullRequestProbeItem] = []

        while page <= Self.workspacePullRequestRepoPageLimit {
            let endpoint = "repos/\(repoSlug)/pulls?state=all&sort=updated&direction=desc&per_page=\(Self.workspacePullRequestRepoPageSize)&page=\(page)"
            guard let response = await performWorkspacePullRequestRequest(
                session: session,
                endpoint: endpoint,
                authHeader: authHeader
            ) else {
#if DEBUG
                cmuxDebugLog("workspace.prRefresh.repo.fail repo=\(repoSlug) page=\(page) status=nil")
#endif
                return .transientFailure
            }

            guard response.statusCode == 200,
                  let pullRequests = decodeJSON([WorkspacePullRequestRESTItem].self, from: response.data) else {
#if DEBUG
                cmuxDebugLog("workspace.prRefresh.repo.fail repo=\(repoSlug) page=\(page) status=\(response.statusCode)")
#endif
                return .transientFailure
            }

            fetchedPageCount += 1
            allPullRequests.append(contentsOf: pullRequests.map(Self.workspacePullRequestProbeItem))
            if pullRequests.count < Self.workspacePullRequestRepoPageSize {
                break
            }
            page += 1
        }

        let recentWindowEntry = WorkspacePullRequestRepoCacheEntry(
            fetchedAt: fetchTimestamp,
            pullRequestsByBranch: pullRequestMapByNormalizedBranch(from: allPullRequests)
        )
        let unresolvedBranches = unresolvedWorkspacePullRequestBranches(
            normalizedCandidateBranches,
            in: recentWindowEntry
        )
        let lookupOutcome: WorkspacePullRequestBranchLookupOutcome
        if unresolvedBranches.isEmpty {
            lookupOutcome = WorkspacePullRequestBranchLookupOutcome(
                cacheEntry: recentWindowEntry,
                transientBranches: []
            )
        } else {
            lookupOutcome = await workspacePullRequestBranchLookupOutcome(
                repoSlug: repoSlug,
                candidateBranches: unresolvedBranches,
                baseEntry: recentWindowEntry,
                refreshedAt: fetchTimestamp,
                session: session,
                authHeader: authHeader
            )
        }
#if DEBUG
        cmuxDebugLog(
            "workspace.prRefresh.repo.success repo=\(repoSlug) pages=\(fetchedPageCount) " +
            "branches=\(lookupOutcome.cacheEntry.pullRequestsByBranch.count) " +
            "branchLookups=\(unresolvedBranches.count) transient=\(lookupOutcome.transientBranches.count)"
        )
#endif
        return .success(
            lookupOutcome.cacheEntry,
            usedCache: false,
            transientBranches: lookupOutcome.transientBranches
        )
    }

    private nonisolated static func unresolvedWorkspacePullRequestBranches(
        _ candidateBranches: Set<String>,
        in cacheEntry: WorkspacePullRequestRepoCacheEntry
    ) -> [String] {
        candidateBranches
            .filter {
                cacheEntry.pullRequestsByBranch[$0] == nil
                    && !cacheEntry.knownAbsentBranches.contains($0)
            }
            .sorted()
    }

    private nonisolated static func workspacePullRequestBranchLookupOutcome(
        repoSlug: String,
        candidateBranches: [String],
        baseEntry: WorkspacePullRequestRepoCacheEntry,
        refreshedAt: Date,
        session: URLSession,
        authHeader: String?
    ) async -> WorkspacePullRequestBranchLookupOutcome {
        guard !candidateBranches.isEmpty else {
            return WorkspacePullRequestBranchLookupOutcome(
                cacheEntry: baseEntry,
                transientBranches: []
            )
        }

        let branchResults = await withTaskGroup(
            of: (String, WorkspacePullRequestBranchFetchResult).self,
            returning: [(String, WorkspacePullRequestBranchFetchResult)].self
        ) { group in
            for branch in candidateBranches {
                group.addTask {
                    let result = await Self.workspacePullRequestBranchFetchResult(
                        repoSlug: repoSlug,
                        branch: branch,
                        session: session,
                        authHeader: authHeader
                    )
                    return (branch, result)
                }
            }

            var collected: [(String, WorkspacePullRequestBranchFetchResult)] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        var pullRequestsByBranch = baseEntry.pullRequestsByBranch
        var knownAbsentBranches = baseEntry.knownAbsentBranches
        var transientBranches: Set<String> = []

        for (branch, result) in branchResults {
            switch result {
            case .found(let pullRequest):
                pullRequestsByBranch[branch] = pullRequest
                knownAbsentBranches.remove(branch)
            case .notFound:
                knownAbsentBranches.insert(branch)
            case .transientFailure:
                transientBranches.insert(branch)
            }
        }

        return WorkspacePullRequestBranchLookupOutcome(
            cacheEntry: WorkspacePullRequestRepoCacheEntry(
                fetchedAt: refreshedAt,
                pullRequestsByBranch: pullRequestsByBranch,
                knownAbsentBranches: knownAbsentBranches
            ),
            transientBranches: transientBranches
        )
    }

    private nonisolated static func workspacePullRequestBranchFetchResult(
        repoSlug: String,
        branch: String,
        session: URLSession,
        authHeader: String?
    ) async -> WorkspacePullRequestBranchFetchResult {
        guard let endpoint = workspacePullRequestBranchEndpoint(
            repoSlug: repoSlug,
            branch: branch
        ) else {
            return .transientFailure
        }

        guard let response = await performWorkspacePullRequestRequest(
            session: session,
            endpoint: endpoint,
            authHeader: authHeader
        ) else {
#if DEBUG
            cmuxDebugLog("workspace.prRefresh.branch.fail repo=\(repoSlug) branch=\(branch) status=nil")
#endif
            return .transientFailure
        }

        guard response.statusCode == 200,
              let pullRequests = decodeJSON([WorkspacePullRequestRESTItem].self, from: response.data) else {
#if DEBUG
            cmuxDebugLog(
                "workspace.prRefresh.branch.fail repo=\(repoSlug) " +
                "branch=\(branch) status=\(response.statusCode)"
            )
#endif
            return .transientFailure
        }

        let matchingPullRequests = pullRequests
            .map(Self.workspacePullRequestProbeItem)
            .filter { normalizedBranchName($0.headRefName) == branch }
        if let preferredPullRequest = preferredPullRequest(from: matchingPullRequests) {
            return .found(preferredPullRequest)
        }
        return .notFound
    }

    private nonisolated static func workspacePullRequestBranchEndpoint(
        repoSlug: String,
        branch: String
    ) -> String? {
        let components = repoSlug.split(separator: "/", maxSplits: 1).map(String.init)
        guard components.count == 2,
              !components[0].isEmpty,
              !components[1].isEmpty else {
            return nil
        }

        var query = URLComponents()
        query.queryItems = [
            URLQueryItem(name: "state", value: "all"),
            URLQueryItem(name: "head", value: "\(components[0]):\(branch)"),
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "direction", value: "desc"),
            URLQueryItem(name: "per_page", value: String(Self.workspacePullRequestRepoPageSize)),
        ]
        guard let percentEncodedQuery = query.percentEncodedQuery else {
            return nil
        }
        return "repos/\(repoSlug)/pulls?\(percentEncodedQuery)"
    }

    private nonisolated static func workspacePullRequestProbeItem(
        from pullRequest: WorkspacePullRequestRESTItem
    ) -> GitHubPullRequestProbeItem {
        let rawState = pullRequest.mergedAt?.isEmpty == false ? "MERGED" : pullRequest.state
        return GitHubPullRequestProbeItem(
            number: pullRequest.number,
            state: rawState,
            url: pullRequest.htmlURL,
            updatedAt: pullRequest.updatedAt,
            mergedAt: pullRequest.mergedAt,
            headRefName: pullRequest.head.ref,
            baseRefName: pullRequest.base?.ref
        )
    }

    private nonisolated static func performWorkspacePullRequestRequest(
        session: URLSession,
        endpoint: String,
        authHeader: String?
    ) async -> WorkspacePullRequestHTTPResponse? {
        guard let url = URL(string: "https://api.github.com/\(endpoint)") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("cmux-workspace-pr-poller", forHTTPHeaderField: "User-Agent")
        if let authHeader, !authHeader.isEmpty {
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return nil
            }
            return WorkspacePullRequestHTTPResponse(
                statusCode: httpResponse.statusCode,
                data: data
            )
        } catch {
            return nil
        }
    }

    private nonisolated static func workspacePullRequestAuthHeaderValue() async -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let envToken = environment["GH_TOKEN"] ?? environment["GITHUB_TOKEN"] {
            let trimmed = envToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return "Bearer \(trimmed)"
            }
        }

        let directory = FileManager.default.currentDirectoryPath
        let token = await runCommand(
            directory: directory,
            executable: "gh",
            arguments: ["auth", "token"],
            timeout: workspacePullRequestProbeTimeout
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else { return nil }
        return "Bearer \(token)"
    }

    nonisolated static func pullRequestMapByNormalizedBranchForTesting(
        from pullRequests: [GitHubPullRequestProbeItem],
        now: Date
    ) -> [String: GitHubPullRequestProbeItem] {
        pullRequestMapByNormalizedBranch(from: pullRequests, now: now)
    }

    private nonisolated static func pullRequestMapByNormalizedBranch(
        from pullRequests: [GitHubPullRequestProbeItem],
        now: Date = Date()
    ) -> [String: GitHubPullRequestProbeItem] {
        var pullRequestsByBranch: [String: GitHubPullRequestProbeItem] = [:]

        for pullRequest in pullRequests {
            guard let branch = normalizedBranchName(pullRequest.headRefName),
                  isSidebarPullRequestCandidate(pullRequest, now: now) else {
                continue
            }

            if let currentBest = pullRequestsByBranch[branch] {
                pullRequestsByBranch[branch] = preferredPullRequest(
                    from: [currentBest, pullRequest],
                    now: now
                ) ?? currentBest
            } else {
                pullRequestsByBranch[branch] = pullRequest
            }
        }

        return pullRequestsByBranch
    }

    nonisolated static func preferredPullRequest(
        from pullRequests: [GitHubPullRequestProbeItem],
        now: Date = Date()
    ) -> GitHubPullRequestProbeItem? {
        func statusPriority(_ status: SidebarPullRequestStatus) -> Int {
            switch status {
            case .open:
                return 3
            case .merged:
                return 2
            case .closed:
                return 1
            }
        }

        func isPreferred(
            candidate: GitHubPullRequestProbeItem,
            over current: GitHubPullRequestProbeItem
        ) -> Bool {
            guard let candidateStatus = pullRequestStatus(from: candidate.state),
                  let currentStatus = pullRequestStatus(from: current.state) else {
                return false
            }

            let candidatePriority = statusPriority(candidateStatus)
            let currentPriority = statusPriority(currentStatus)
            if candidatePriority != currentPriority {
                return candidatePriority > currentPriority
            }

            let candidateUpdatedAt = candidate.updatedAt ?? ""
            let currentUpdatedAt = current.updatedAt ?? ""
            if candidateUpdatedAt != currentUpdatedAt {
                return candidateUpdatedAt > currentUpdatedAt
            }

            return candidate.number > current.number
        }

        var best: GitHubPullRequestProbeItem?
        for pullRequest in pullRequests {
            guard isSidebarPullRequestCandidate(pullRequest, now: now) else {
                continue
            }
            guard let currentBest = best else {
                best = pullRequest
                continue
            }
            if isPreferred(candidate: pullRequest, over: currentBest) {
                best = pullRequest
            }
        }
        return best
    }

    private nonisolated static func isSidebarPullRequestCandidate(
        _ pullRequest: GitHubPullRequestProbeItem,
        now: Date
    ) -> Bool {
        guard pullRequestStatus(from: pullRequest.state) != nil,
              URL(string: pullRequest.url) != nil else {
            return false
        }
        return !isStaleMergedPullRequest(pullRequest, now: now)
    }

    private nonisolated static func isStaleMergedPullRequest(
        _ pullRequest: GitHubPullRequestProbeItem,
        now: Date
    ) -> Bool {
        guard pullRequestStatus(from: pullRequest.state) == .merged,
              let mergedAt = githubTimestampDate(from: pullRequest.mergedAt) else {
            return false
        }
        return now.timeIntervalSince(mergedAt) > mergedPullRequestBadgeStaleAfter
    }

    private nonisolated static func githubTimestampDate(from rawTimestamp: String?) -> Date? {
        let timestamp = rawTimestamp?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !timestamp.isEmpty else { return nil }

        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: timestamp) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: timestamp)
    }

    private nonisolated static func pullRequestStatus(
        from rawState: String
    ) -> SidebarPullRequestStatus? {
        switch rawState.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "OPEN":
            return .open
        case "MERGED":
            return .merged
        case "CLOSED":
            return .closed
        default:
            return nil
        }
    }

    private nonisolated static func decodeJSON<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private nonisolated static func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(T.self, from: data)
    }

    private nonisolated static let fallbackCommandSearchDirectories: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
    ]

    nonisolated static func resolvedCommandPathForTesting(
        executable: String,
        environment: [String: String],
        fallbackDirectories: [String]
    ) -> String? {
        resolvedCommandPath(
            executable: executable,
            environment: environment,
            fallbackDirectories: fallbackDirectories
        )
    }

    private nonisolated static func resolvedCommandPath(
        executable: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fallbackDirectories: [String] = fallbackCommandSearchDirectories
    ) -> String? {
        guard !executable.isEmpty else { return nil }
        let fileManager = FileManager.default
        if executable.contains("/") {
            return fileManager.isExecutableFile(atPath: executable) ? executable : nil
        }

        var searchDirectories: [String] = []
        var seenDirectories: Set<String> = []

        func appendSearchPath(_ path: String?) {
            guard let path else { return }
            for rawComponent in path.split(separator: ":") {
                let component = String(rawComponent).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !component.isEmpty,
                      seenDirectories.insert(component).inserted else {
                    continue
                }
                searchDirectories.append(component)
            }
        }

        appendSearchPath(environment["PATH"])
        appendSearchPath(getenv("PATH").map { String(cString: $0) })
        if let bundledBinPath = Bundle.main.resourceURL?.appendingPathComponent("bin").path {
            appendSearchPath(bundledBinPath)
        }
        fallbackDirectories.forEach { appendSearchPath($0) }
        appendSearchPath("/usr/bin:/bin:/usr/sbin:/sbin")

        for directory in searchDirectories {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(executable)
                .path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private final class CommandRunState: @unchecked Sendable {
        fileprivate typealias Continuation = CheckedContinuation<CommandResult?, Never>

        private let lock = NSLock()
        private var continuation: Continuation?
        private var stdoutData: Data?
        private var stderrData: Data?
        private var exitStatus: Int32?
        private var didTerminate = false
        private var didResume = false
        private var timeoutWorkItem: DispatchWorkItem?

        fileprivate init(continuation: Continuation) {
            self.continuation = continuation
        }

        func setTimeoutWorkItem(_ item: DispatchWorkItem?) {
            guard let item else { return }
            lock.lock()
            if didResume {
                lock.unlock()
                item.cancel()
                return
            }
            timeoutWorkItem = item
            lock.unlock()
        }

        func hasResumed() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return didResume
        }

        func completeStdout(_ data: Data) {
            complete {
                stdoutData = data
            }
        }

        func completeStderr(_ data: Data) {
            complete {
                stderrData = data
            }
        }

        func completeTermination(exitStatus: Int32) {
            complete {
                self.exitStatus = exitStatus
                didTerminate = true
            }
        }

        func resume(returning result: CommandResult?) {
            var continuationToResume: Continuation?
            var timeoutToCancel: DispatchWorkItem?
            lock.lock()
            guard !didResume else {
                lock.unlock()
                return
            }
            didResume = true
            continuationToResume = continuation
            continuation = nil
            timeoutToCancel = timeoutWorkItem
            timeoutWorkItem = nil
            lock.unlock()

            timeoutToCancel?.cancel()
            continuationToResume?.resume(returning: result)
        }

        private func complete(_ mutate: () -> Void) {
            var continuationToResume: Continuation?
            var timeoutToCancel: DispatchWorkItem?
            var resultToResume: CommandResult?

            lock.lock()
            guard !didResume else {
                lock.unlock()
                return
            }

            mutate()
            if let stdoutData,
               let stderrData,
               didTerminate {
                didResume = true
                resultToResume = CommandResult(
                    stdout: String(data: stdoutData, encoding: .utf8),
                    stderr: String(data: stderrData, encoding: .utf8),
                    exitStatus: exitStatus,
                    timedOut: false,
                    executionError: nil
                )
                continuationToResume = continuation
                continuation = nil
                timeoutToCancel = timeoutWorkItem
                timeoutWorkItem = nil
            }
            lock.unlock()

            timeoutToCancel?.cancel()
            if let resultToResume {
                continuationToResume?.resume(returning: resultToResume)
            }
        }
    }

    private nonisolated static func runCommand(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval? = nil
    ) async -> String? {
        let result = await runCommandResult(
            directory: directory,
            executable: executable,
            arguments: arguments,
            timeout: timeout
        )
        guard let result,
              result.exitStatus == 0,
              !result.timedOut else {
            return nil
        }
        return result.stdout
    }

    private nonisolated static func runCommandResult(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval? = nil
    ) async -> CommandResult? {
#if DEBUG
        assert(!Thread.isMainThread, "TabManager.runCommandResult must not run on the main thread")
        if let commandRunnerForTesting {
            return commandRunnerForTesting(directory, executable, arguments, timeout)
        }
#endif
        return await withCheckedContinuation { continuation in
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            if let resolvedExecutable = resolvedCommandPath(executable: executable) {
                process.executableURL = URL(fileURLWithPath: resolvedExecutable)
                process.arguments = arguments
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [executable] + arguments
            }
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = stdout
            process.standardError = stderr

            let state = CommandRunState(continuation: continuation)
            let timeoutWorkItem = timeout.map { _ in
                DispatchWorkItem { [state, process] in
                    guard !state.hasResumed() else { return }
                    guard process.isRunning else { return }
                    process.terminate()
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) {
                        if process.isRunning {
                            kill(process.processIdentifier, SIGKILL)
                        }
                    }
                    state.resume(
                        returning: CommandResult(
                            stdout: nil,
                            stderr: nil,
                            exitStatus: nil,
                            timedOut: true,
                            executionError: nil
                        )
                    )
                }
            }
            state.setTimeoutWorkItem(timeoutWorkItem)
            process.terminationHandler = { terminatedProcess in
                state.completeTermination(exitStatus: terminatedProcess.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                try? stdout.fileHandleForWriting.close()
                try? stderr.fileHandleForWriting.close()
                state.resume(
                    returning: CommandResult(
                        stdout: nil,
                        stderr: nil,
                        exitStatus: nil,
                        timedOut: false,
                        executionError: String(describing: error)
                    )
                )
                return
            }

            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()

            DispatchQueue.global(qos: .utility).async {
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                state.completeStdout(data)
            }
            DispatchQueue.global(qos: .utility).async {
                let data = stderr.fileHandleForReading.readDataToEndOfFile()
                state.completeStderr(data)
            }
            if let timeout,
               let timeoutWorkItem {
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + timeout,
                    execute: timeoutWorkItem
                )
            }
        }
    }

    nonisolated static func githubRepositorySlugs(fromGitRemoteVOutput output: String) -> [String] {
        var slugByRemoteName: [String: String] = [:]

        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 3 else { continue }

            let remoteName = String(parts[0])
            let remoteURL = String(parts[1])
            let remoteKind = String(parts[2])
            guard remoteKind == "(fetch)",
                  let repoSlug = githubRepositorySlug(fromRemoteURL: remoteURL) else {
                continue
            }

            slugByRemoteName[remoteName] = repoSlug
        }

        let orderedRemoteNames = slugByRemoteName.keys.sorted { lhs, rhs in
            let lhsPriority = githubRemotePriority(lhs)
            let rhsPriority = githubRemotePriority(rhs)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return lhs < rhs
        }

        var orderedSlugs: [String] = []
        var seen: Set<String> = []
        for remoteName in orderedRemoteNames {
            guard let repoSlug = slugByRemoteName[remoteName],
                  seen.insert(repoSlug).inserted else {
                continue
            }
            orderedSlugs.append(repoSlug)
        }
        return orderedSlugs
    }

#if DEBUG
    nonisolated static func workspaceGitMetadataWatchedPathsForTesting(directory: String) -> [String] {
        workspaceGitMetadataWatcherDescriptor(for: directory)?.watchedPaths ?? []
    }

    nonisolated static func githubRepositorySlugs(fromGitConfigForTesting config: String) -> [String] {
        githubRepositorySlugs(fromGitRemoteVOutput: gitRemoteVLines(fromConfig: config).joined())
    }

    nonisolated static func githubRepositorySlugs(directoryForTesting directory: String) -> [String] {
        guard let repository = resolveGitRepository(containing: directory),
              let output = gitRemoteVOutput(repository: repository) else {
            return []
        }
        return githubRepositorySlugs(fromGitRemoteVOutput: output)
    }
#endif

    #if compiler(>=6.2)
    @concurrent
    #endif
    private nonisolated static func githubRepositorySlugs(directory: String) async -> [String] {
        guard let repository = resolveGitRepository(containing: directory),
              let output = gitRemoteVOutput(repository: repository) else {
            return []
        }
        return githubRepositorySlugs(fromGitRemoteVOutput: output)
    }

    private nonisolated static func githubRemotePriority(_ remoteName: String) -> Int {
        switch remoteName.lowercased() {
        case "upstream":
            return 0
        case "origin":
            return 1
        default:
            return 2
        }
    }

    private nonisolated static func githubRepositorySlug(fromRemoteURL remoteURL: String) -> String? {
        let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let githubPrefixes = [
            "git@github.com:",
            "ssh://git@github.com/",
            "https://github.com/",
            "http://github.com/",
            "git://github.com/",
        ]
        for prefix in githubPrefixes where trimmed.hasPrefix(prefix) {
            let path = String(trimmed.dropFirst(prefix.count))
            return normalizedGitHubRepositorySlug(path)
        }

        guard let url = URL(string: trimmed),
              let host = url.host?.lowercased(),
              host == "github.com" else {
            return nil
        }

        return normalizedGitHubRepositorySlug(url.path)
    }

    private nonisolated static func githubRepositorySlug(fromPullRequestURL url: URL) -> String? {
        guard let host = url.host?.lowercased(),
              host == "github.com" else {
            return nil
        }
        return normalizedGitHubRepositorySlug(url.path)
    }

    private nonisolated static func normalizedGitHubRepositorySlug(_ rawPath: String) -> String? {
        let trimmedPath = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedPath.isEmpty else { return nil }
        let components = trimmedPath.split(separator: "/").map(String.init)
        guard components.count >= 2 else { return nil }
        let owner = components[0]
        var repo = components[1]
        if repo.hasSuffix(".git") {
            repo.removeLast(4)
        }
        guard !owner.isEmpty, !repo.isEmpty else { return nil }
        return "\(owner)/\(repo)"
    }

    private nonisolated static func debugLogSnippet(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(180))
    }

    private nonisolated static func normalizedBranchName(_ branch: String?) -> String? {
        let trimmed = branch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated static func shouldSkipWorkspacePullRequestLookup(branch: String) -> Bool {
        switch normalizedBranchName(branch) {
        case "main", "master":
            return true
        default:
            return false
        }
    }

    func requestBackgroundWorkspaceLoad(for workspaceId: UUID) {
        guard !pendingBackgroundWorkspaceLoadIds.contains(workspaceId) else { return }
        var updated = pendingBackgroundWorkspaceLoadIds
        updated.insert(workspaceId)
        pendingBackgroundWorkspaceLoadIds = updated
    }

    func completeBackgroundWorkspaceLoad(for workspaceId: UUID) {
        guard pendingBackgroundWorkspaceLoadIds.contains(workspaceId) else { return }
        var updated = pendingBackgroundWorkspaceLoadIds
        updated.remove(workspaceId)
        pendingBackgroundWorkspaceLoadIds = updated
        releaseBackgroundWorkspaceMount(for: workspaceId)
    }

    func retainBackgroundWorkspaceMount(for workspaceId: UUID) {
        guard !mountedBackgroundWorkspaceLoadIds.contains(workspaceId) else { return }
        var updated = mountedBackgroundWorkspaceLoadIds
        updated.insert(workspaceId)
        mountedBackgroundWorkspaceLoadIds = updated
    }

    func releaseBackgroundWorkspaceMount(for workspaceId: UUID) {
        guard mountedBackgroundWorkspaceLoadIds.contains(workspaceId) else { return }
        var updated = mountedBackgroundWorkspaceLoadIds
        updated.remove(workspaceId)
        mountedBackgroundWorkspaceLoadIds = updated
    }

    func retainDebugWorkspaceLoads(for workspaceIds: Set<UUID>) {
        guard !workspaceIds.isEmpty else { return }
        var updated = debugPinnedWorkspaceLoadIds
        updated.formUnion(workspaceIds)
        guard updated != debugPinnedWorkspaceLoadIds else { return }
        debugPinnedWorkspaceLoadIds = updated
    }

    func releaseDebugWorkspaceLoads(for workspaceIds: Set<UUID>) {
        guard !workspaceIds.isEmpty else { return }
        var updated = debugPinnedWorkspaceLoadIds
        updated.subtract(workspaceIds)
        guard updated != debugPinnedWorkspaceLoadIds else { return }
        debugPinnedWorkspaceLoadIds = updated
    }

    func pruneBackgroundWorkspaceLoads(existingIds: Set<UUID>) {
        let pruned = pendingBackgroundWorkspaceLoadIds.intersection(existingIds)
        if pruned != pendingBackgroundWorkspaceLoadIds {
            pendingBackgroundWorkspaceLoadIds = pruned
        }
        let mounted = mountedBackgroundWorkspaceLoadIds.intersection(existingIds)
        if mounted != mountedBackgroundWorkspaceLoadIds {
            mountedBackgroundWorkspaceLoadIds = mounted
        }
        let retained = debugPinnedWorkspaceLoadIds.intersection(existingIds)
        if retained != debugPinnedWorkspaceLoadIds {
            debugPinnedWorkspaceLoadIds = retained
        }
    }

    // Keep addTab as convenience alias
    @discardableResult
    func addTab(select: Bool = true, eagerLoadTerminal: Bool = false) -> Workspace {
        addWorkspace(select: select, eagerLoadTerminal: eagerLoadTerminal)
    }

    func terminalPanelForWorkspaceConfigInheritanceSource() -> TerminalPanel? {
        terminalPanelForWorkspaceConfigInheritanceSource(workspace: selectedWorkspace)
    }

    /// Build a snapshot using pre-extracted value-type data. The caller is responsible
    /// for obtaining `preferredWorkingDirectory` and `inheritedTerminalFontPoints` through
    /// `self` (where `self.tabs` keeps all Workspace objects alive) so that no local
    /// Workspace references are needed here.
    func workspaceCreationSnapshotLite(
        currentTabs: [Workspace],
        currentSelectedTabId: UUID?,
        preferredWorkingDirectory: String?,
        inheritedTerminalFontPoints: Float?
    ) -> WorkspaceCreationSnapshot {
        var tabSnapshots: [WorkspaceCreationTabSnapshot] = []
        tabSnapshots.reserveCapacity(currentTabs.count)
        for workspace in currentTabs {
            // Keep each Workspace alive while copying the tiny value snapshot out of it.
            // The optimized arm64 Nightly build can otherwise over-release during
            // Collection.map, crashing here in swift_release / snapshot creation.
            let snapshot = withExtendedLifetime(workspace) {
                WorkspaceCreationTabSnapshot(workspace: workspace)
            }
            tabSnapshots.append(snapshot)
        }
        let selectedTabSnapshot = currentSelectedTabId.flatMap { selectedTabId in
            tabSnapshots.first(where: { $0.id == selectedTabId })
        }

        return WorkspaceCreationSnapshot(
            tabs: tabSnapshots,
            selectedTabId: currentSelectedTabId,
            selectedTabWasPinned: selectedTabSnapshot?.isPinned ?? false,
            preferredWorkingDirectory: preferredWorkingDirectory,
            inheritedTerminalFontPoints: inheritedTerminalFontPoints
        )
    }

    private func workspaceCreationSnapshot() -> WorkspaceCreationSnapshot {
        workspaceCreationSnapshotLite(
            currentTabs: tabs,
            currentSelectedTabId: selectedTabId,
            preferredWorkingDirectory: preferredWorkingDirectoryForNewTab(),
            inheritedTerminalFontPoints: inheritedTerminalFontPointsForNewWorkspace()
        )
    }

    private func orderedLiveWorkspaceCreationTabs(
        from snapshot: WorkspaceCreationSnapshot
    ) -> [WorkspaceCreationTabSnapshot]? {
        let currentTabs = tabs
        let snapshotTabsById = Dictionary(uniqueKeysWithValues: snapshot.tabs.map { ($0.id, $0) })
        var orderedTabs: [WorkspaceCreationTabSnapshot] = []
        orderedTabs.reserveCapacity(currentTabs.count)

        for workspace in currentTabs {
            guard let tabSnapshot = snapshotTabsById[workspace.id] else {
#if DEBUG
                cmuxDebugLog(
                    "workspace.create.reentrantSnapshotFallback " +
                    "snapshotCount=\(snapshot.tabs.count) liveCount=\(currentTabs.count)"
                )
#endif
                return nil
            }
            orderedTabs.append(tabSnapshot)
        }

        return orderedTabs
    }

    private func terminalPanelForWorkspaceConfigInheritanceSource(
        workspace: Workspace?
    ) -> TerminalPanel? {
        guard let workspace else { return nil }
        // Prefer cached/published panel state here instead of walking live Bonsplit focus
        // during Cmd+N; rapid workspace creation can observe transient pane/tab selection.
        let panels = workspace.panels
        var candidates: [TerminalPanel] = []
        var seen: Set<UUID> = []

        func appendCandidate(_ panel: TerminalPanel?) {
            guard let panel, seen.insert(panel.id).inserted else { return }
            candidates.append(panel)
        }

        appendCandidate(workspace.lastRememberedTerminalPanelForConfigInheritance())
        for terminalPanel in panels.values
            .compactMap({ $0 as? TerminalPanel })
            .sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            appendCandidate(terminalPanel)
        }

        if let livePanel = candidates.first(where: { $0.surface.hasLiveSurface && $0.surface.surface != nil }) {
            return livePanel
        }
        return candidates.first
    }

    private func inheritedTerminalConfigForNewWorkspace() -> CmuxSurfaceConfigTemplate? {
        inheritedTerminalConfigForNewWorkspace(workspace: selectedWorkspace)
    }

    private func cachedInheritedTerminalFontPointsForNewWorkspace(
        workspace: Workspace?
    ) -> Float? {
        guard let workspace else { return nil }
        // New workspace creation only seeds font size into a fresh Swift-owned template.
        // Avoid reading live panel/surface state here; the arm64 Nightly Cmd+N crash path
        // was repeatedly dereferencing pointer-backed terminal objects while preparing the
        // new workspace. The workspace already caches the rooted font lineage we need.
        return withExtendedLifetime(workspace) {
            guard let fontPoints = workspace.lastRememberedTerminalFontPointsForConfigInheritance(),
                  fontPoints > 0 else {
                return nil
            }
            return fontPoints
        }
    }

    func inheritedTerminalConfigForNewWorkspace(
        workspace: Workspace?
    ) -> CmuxSurfaceConfigTemplate? {
        guard let fontPoints = cachedInheritedTerminalFontPointsForNewWorkspace(workspace: workspace) else {
            return nil
        }
        var config = CmuxSurfaceConfigTemplate()
        config.fontSize = fontPoints
        return config
    }

    private func inheritedTerminalFontPointsForNewWorkspace() -> Float? {
        inheritedTerminalFontPointsForNewWorkspace(workspace: selectedWorkspace)
    }

    func inheritedTerminalFontPointsForNewWorkspace(
        workspace: Workspace?
    ) -> Float? {
        cachedInheritedTerminalFontPointsForNewWorkspace(workspace: workspace)
    }

    func workspaceCreationConfigTemplate(
        inheritedTerminalFontPoints: Float?
    ) -> CmuxSurfaceConfigTemplate? {
        guard let inheritedTerminalFontPoints, inheritedTerminalFontPoints > 0 else {
            return nil
        }
        // Rebuild a clean Swift-owned template instead of carrying over any pointer-backed
        // inherited config state from the source workspace.
        var config = CmuxSurfaceConfigTemplate()
        config.fontSize = inheritedTerminalFontPoints
        return config
    }

    func normalizedWorkingDirectory(_ directory: String?) -> String? {
        guard let directory else { return nil }
        let normalized = normalizeDirectory(directory)
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : normalized
    }

    private func newTabInsertIndex(placementOverride: NewWorkspacePlacement? = nil) -> Int {
        newTabInsertIndex(snapshot: workspaceCreationSnapshot(), placementOverride: placementOverride)
    }

    func newTabInsertIndex(
        snapshot: WorkspaceCreationSnapshot,
        placementOverride: NewWorkspacePlacement? = nil
    ) -> Int {
        let placement = WorkspacePlacementSettings.effectivePlacement(placementOverride: placementOverride)
        let liveTabs = orderedLiveWorkspaceCreationTabs(from: snapshot) ?? snapshot.tabs
        let pinnedCount = liveTabs.reduce(into: 0) { partial, tab in
            if tab.isPinned {
                partial += 1
            }
        }

        switch placement {
        case .top:
            return pinnedCount
        case .end:
            return liveTabs.count
        case .afterCurrent:
            if let selectedTabId = snapshot.selectedTabId,
               let selectedIndex = liveTabs.firstIndex(where: { $0.id == selectedTabId }) {
                return WorkspacePlacementSettings.insertionIndex(
                    placement: placement,
                    selectedIndex: selectedIndex,
                    selectedIsPinned: snapshot.selectedTabWasPinned,
                    pinnedCount: pinnedCount,
                    totalCount: liveTabs.count
                )
            }
            return snapshot.selectedTabWasPinned ? pinnedCount : liveTabs.count
        }
    }

    private func preferredWorkingDirectoryForNewTab() -> String? {
        preferredWorkingDirectoryForNewTab(workspace: selectedWorkspace)
    }

    func preferredWorkingDirectoryForNewTab(
        workspace: Workspace?
    ) -> String? {
        guard let workspace else {
            return nil
        }
        // Use cached directory state only; avoiding live focus traversal keeps workspace
        // creation resilient when Bonsplit is in the middle of a rapid Cmd+N churn.
        if let currentDirectory = normalizedWorkingDirectory(workspace.currentDirectory) {
            return currentDirectory
        }

        return workspace.panelDirectories.values.lazy.compactMap { directory in
            self.normalizedWorkingDirectory(directory)
        }.first
    }

    func implicitWorkingDirectoryForNewWorkspace(from sourceWorkspace: Workspace?) -> String? {
        guard WorkspaceWorkingDirectoryInheritanceSettings.isEnabled() else {
            return nil
        }
        return preferredWorkingDirectoryForNewTab(workspace: sourceWorkspace)
    }

    func moveTabToTop(_ tabId: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let tab = tabs[index]
        let targetIndex = tab.isPinned ? 0 : tabs.filter { $0.isPinned }.count
        guard index != targetIndex else { return }
        tabs.remove(at: index)
        let pinnedCount = tabs.filter { $0.isPinned }.count
        let insertIndex = tab.isPinned ? 0 : pinnedCount
        tabs.insert(tab, at: insertIndex)
        postWorkspaceOrderDidChange(movedWorkspaceIds: [tabId])
    }

    func moveTabsToTop(_ tabIds: Set<UUID>) {
        guard !tabIds.isEmpty else { return }
        let selectedTabs = tabs.filter { tabIds.contains($0.id) }
        guard !selectedTabs.isEmpty else { return }
        let previousOrder = tabs.map(\.id)
        let remainingTabs = tabs.filter { !tabIds.contains($0.id) }
        let selectedPinned = selectedTabs.filter { $0.isPinned }
        let selectedUnpinned = selectedTabs.filter { !$0.isPinned }
        let remainingPinned = remainingTabs.filter { $0.isPinned }
        let remainingUnpinned = remainingTabs.filter { !$0.isPinned }
        tabs = selectedPinned + remainingPinned + selectedUnpinned + remainingUnpinned
        if tabs.map(\.id) != previousOrder {
            postWorkspaceOrderDidChange(movedWorkspaceIds: selectedTabs.map(\.id))
        }
    }

    func moveTabToTopForNotification(_ tabId: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let pinnedCount = tabs.filter { $0.isPinned }.count
        guard index != pinnedCount else { return }
        let tab = tabs[index]
        guard !tab.isPinned else { return }
        tabs.remove(at: index)
        tabs.insert(tab, at: pinnedCount)
        postWorkspaceOrderDidChange(movedWorkspaceIds: [tabId])
    }

    @discardableResult
    func reorderWorkspace(tabId: UUID, toIndex targetIndex: Int) -> Bool {
        guard let plan = workspaceReorderPlan(tabId: tabId, toIndex: targetIndex) else { return false }
        if tabs.count <= 1 || plan.fromIndex == plan.toIndex { return true }

        let workspace = tabs.remove(at: plan.fromIndex)
        tabs.insert(workspace, at: plan.toIndex)
        postWorkspaceOrderDidChange(movedWorkspaceIds: [tabId])
        return true
    }

    func workspaceReorderPlan(tabId: UUID, toIndex targetIndex: Int) -> WorkspaceReorderPlanItem? {
        guard let currentIndex = tabs.firstIndex(where: { $0.id == tabId }) else { return nil }
        if tabs.count <= 1 {
            return WorkspaceReorderPlanItem(workspaceId: tabId, fromIndex: currentIndex, toIndex: currentIndex)
        }

        let workspace = tabs[currentIndex]
        let clamped = clampedReorderIndex(for: workspace, targetIndex: targetIndex)
        return WorkspaceReorderPlanItem(workspaceId: tabId, fromIndex: currentIndex, toIndex: clamped)
    }

    private func postWorkspaceOrderDidChange(movedWorkspaceIds: [UUID]) {
        guard !movedWorkspaceIds.isEmpty else { return }
        NotificationCenter.default.post(
            name: .workspaceOrderDidChange,
            object: self,
            userInfo: [WorkspaceOrderChangeNotificationKey.movedWorkspaceIds: movedWorkspaceIds]
        )
        CmuxEventBus.shared.publishWorkspaceReordered(
            workspaceIds: tabs.map(\.id),
            movedWorkspaceIds: movedWorkspaceIds,
            pinnedWorkspaceIds: tabs.filter(\.isPinned).map(\.id),
            source: "workspace.lifecycle"
        )
    }

    @discardableResult
    func reorderWorkspace(tabId: UUID, before beforeId: UUID? = nil, after afterId: UUID? = nil) -> Bool {
        guard let plan = workspaceReorderPlan(tabId: tabId, before: beforeId, after: afterId) else { return false }
        return reorderWorkspace(tabId: tabId, toIndex: plan.toIndex)
    }

    func workspaceReorderPlan(tabId: UUID, before beforeId: UUID? = nil, after afterId: UUID? = nil) -> WorkspaceReorderPlanItem? {
        guard tabs.contains(where: { $0.id == tabId }) else { return nil }
        if let beforeId {
            guard let idx = tabs.firstIndex(where: { $0.id == beforeId }) else { return nil }
            return workspaceReorderPlan(tabId: tabId, toIndex: idx)
        }
        if let afterId {
            guard let idx = tabs.firstIndex(where: { $0.id == afterId }) else { return nil }
            return workspaceReorderPlan(tabId: tabId, toIndex: idx + 1)
        }
        return nil
    }

    func workspaceBatchReorderPlan(
        orderedWorkspaceIds: [UUID]
    ) -> Result<[WorkspaceReorderPlanItem], WorkspaceBatchReorderError> {
        var seen = Set<UUID>()
        for workspaceId in orderedWorkspaceIds {
            guard seen.insert(workspaceId).inserted else {
                return .failure(.duplicateWorkspace(workspaceId))
            }
        }

        let currentIndexes = Dictionary(uniqueKeysWithValues: tabs.enumerated().map { ($0.element.id, $0.offset) })
        for workspaceId in orderedWorkspaceIds where currentIndexes[workspaceId] == nil {
            return .failure(.workspaceNotFound(workspaceId))
        }

        let finalIds = batchWorkspaceReorderFinalIds(orderedWorkspaceIds: orderedWorkspaceIds)
        let finalIndexes = Dictionary(uniqueKeysWithValues: finalIds.enumerated().map { ($0.element, $0.offset) })

        let plan = orderedWorkspaceIds.map { workspaceId in
            WorkspaceReorderPlanItem(
                workspaceId: workspaceId,
                fromIndex: currentIndexes[workspaceId] ?? 0,
                toIndex: finalIndexes[workspaceId] ?? 0
            )
        }
        return .success(plan)
    }

    @discardableResult
    func reorderWorkspaces(
        orderedWorkspaceIds: [UUID],
        dryRun: Bool = false
    ) -> Result<[WorkspaceReorderPlanItem], WorkspaceBatchReorderError> {
        let result = workspaceBatchReorderPlan(orderedWorkspaceIds: orderedWorkspaceIds)
        guard case .success(let plan) = result else { return result }
        guard !dryRun else { return result }

        let movedWorkspaceIds = plan
            .filter { $0.fromIndex != $0.toIndex }
            .map(\.workspaceId)
        guard !movedWorkspaceIds.isEmpty else { return result }

        let workspacesById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let finalIds = batchWorkspaceReorderFinalIds(orderedWorkspaceIds: orderedWorkspaceIds)
        tabs = finalIds.compactMap { workspacesById[$0] }
        postWorkspaceOrderDidChange(movedWorkspaceIds: movedWorkspaceIds)
        return result
    }

    private func batchWorkspaceReorderFinalIds(orderedWorkspaceIds: [UUID]) -> [UUID] {
        let orderedSet = Set(orderedWorkspaceIds)
        let workspacesById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let orderedPinnedIds = orderedWorkspaceIds.filter { workspacesById[$0]?.isPinned == true }
        let orderedUnpinnedIds = orderedWorkspaceIds.filter { workspacesById[$0]?.isPinned == false }
        let remainingPinnedIds = tabs
            .map(\.id)
            .filter { !orderedSet.contains($0) && workspacesById[$0]?.isPinned == true }
        let remainingUnpinnedIds = tabs
            .map(\.id)
            .filter { !orderedSet.contains($0) && workspacesById[$0]?.isPinned == false }
        return orderedPinnedIds + remainingPinnedIds + orderedUnpinnedIds + remainingUnpinnedIds
    }

    func setCustomTitle(tabId: UUID, title: String?) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        tabs[index].setCustomTitle(title)
        if selectedTabId == tabId {
            updateWindowTitle(for: tabs[index])
        }
    }

    func clearCustomTitle(tabId: UUID) {
        setCustomTitle(tabId: tabId, title: nil)
    }

    func setCustomDescription(tabId: UUID, description: String?) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        tabs[index].setCustomDescription(description)
    }

    func clearCustomDescription(tabId: UUID) {
        setCustomDescription(tabId: tabId, description: nil)
    }

    func setTabColor(tabId: UUID, color: String?) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        tab.setCustomColor(color)
    }

    func applyWorkspaceColor(_ color: String?, toWorkspaceIds workspaceIds: [UUID]) {
        guard !workspaceIds.isEmpty else { return }
        if workspaceIds.count == 1, let workspaceId = workspaceIds.first {
            setTabColor(tabId: workspaceId, color: color)
            return
        }

        let targetIds = Set(workspaceIds)
        for tab in tabs where targetIds.contains(tab.id) {
            tab.setCustomColor(color)
        }
    }

    func applyWorkspacePaletteColor(named name: String, toWorkspaceIds workspaceIds: [UUID]) {
        guard let color = WorkspaceTabColorSettings.currentColorHex(named: name) else { return }
        applyWorkspaceColor(color, toWorkspaceIds: workspaceIds)
    }

    func setWorkspaceTerminalScrollBarHidden(tabId: UUID, hidden: Bool) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        tab.setTerminalScrollBarHidden(hidden)
    }

    func setWorkspaceTerminalScrollBarHidden(hidden: Bool, forWorkspaceIds workspaceIds: [UUID]) {
        guard !workspaceIds.isEmpty else { return }
        if workspaceIds.count == 1, let workspaceId = workspaceIds.first {
            setWorkspaceTerminalScrollBarHidden(tabId: workspaceId, hidden: hidden)
            return
        }

        let targetIds = Set(workspaceIds)
        for tab in tabs where targetIds.contains(tab.id) {
            tab.setTerminalScrollBarHidden(hidden)
        }
    }

    func togglePin(tabId: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let tab = tabs[index]
        setPinned(tab, pinned: !tab.isPinned)
    }

    func setPinned(_ tab: Workspace, pinned: Bool) {
        guard tab.isPinned != pinned else { return }
        tab.isPinned = pinned
        reorderTabForPinnedState(tab)
        postWorkspaceOrderDidChange(movedWorkspaceIds: [tab.id])
    }

    @discardableResult
    func setPinned(workspaceIds: [UUID], pinned: Bool) -> [UUID] {
        guard !workspaceIds.isEmpty else { return [] }
        if workspaceIds.count == 1,
           let workspaceId = workspaceIds.first,
           let tab = tabs.first(where: { $0.id == workspaceId }) {
            let changed = tab.isPinned != pinned
            setPinned(tab, pinned: pinned)
            return changed ? [workspaceId] : []
        }

        var seen = Set<UUID>()
        let orderedTargetIds = workspaceIds.filter { seen.insert($0).inserted }
        let targetIds = Set(orderedTargetIds)
        var workspacesById: [UUID: Workspace] = [:]
        var changedIdSet = Set<UUID>()

        for workspace in tabs {
            workspacesById[workspace.id] = workspace
            guard targetIds.contains(workspace.id), workspace.isPinned != pinned else { continue }
            workspace.isPinned = pinned
            changedIdSet.insert(workspace.id)
        }

        guard !changedIdSet.isEmpty else { return [] }
        let changedIds = orderedTargetIds.filter { changedIdSet.contains($0) }

        let changedWorkspaces: [Workspace]
        if pinned {
            changedWorkspaces = changedIds.compactMap { workspacesById[$0] }
        } else {
            // Keep parity with reorderTabForPinnedState: each unpinned item
            // is inserted at the front of the unpinned segment, so rebuilding a
            // batch in one pass must reverse the changed input order.
            changedWorkspaces = changedIds.reversed().compactMap { workspacesById[$0] }
        }

        let remainingPinned = tabs.filter { $0.isPinned && !changedIdSet.contains($0.id) }
        let remainingUnpinned = tabs.filter { !$0.isPinned && !changedIdSet.contains($0.id) }
        tabs = remainingPinned + changedWorkspaces + remainingUnpinned
        postWorkspaceOrderDidChange(movedWorkspaceIds: changedIds)
        return changedIds
    }

    private func reorderTabForPinnedState(_ tab: Workspace) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        let pinnedCount = tabs.filter { $0.isPinned }.count
        let insertIndex = min(pinnedCount, tabs.count)
        tabs.insert(tab, at: insertIndex)
    }

    private func clampedReorderIndex(for workspace: Workspace, targetIndex: Int) -> Int {
        let clamped = max(0, min(targetIndex, tabs.count - 1))
        let pinnedCount = tabs.filter { $0.isPinned }.count
        if workspace.isPinned {
            return min(clamped, max(0, pinnedCount - 1))
        }
        return max(clamped, pinnedCount)
    }

    // MARK: - Surface Directory Updates (Backwards Compatibility)

    func updateSurfaceDirectory(tabId: UUID, surfaceId: UUID, directory: String) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        let previousDirectory = gitProbeDirectory(for: tab, panelId: surfaceId)
        let normalized = normalizeDirectory(directory)
        tab.updatePanelDirectory(panelId: surfaceId, directory: normalized)
        let nextDirectory = normalizedWorkingDirectory(normalized)
        if previousDirectory != nextDirectory {
            guard sidebarGitMetadataWatchEnabled else {
                clearWorkspaceGitMetadata(for: WorkspaceGitProbeKey(workspaceId: tabId, panelId: surfaceId))
                return
            }
            scheduleWorkspacePullRequestRefresh(
                workspaceId: tabId,
                panelId: surfaceId,
                reason: "directoryChange"
            )
            scheduleWorkspaceGitMetadataRefreshIfPossible(
                workspaceId: tabId,
                panelId: surfaceId,
                reason: "directoryChange"
            )
        }
    }

    func updateSurfaceGitBranch(
        tabId: UUID,
        surfaceId: UUID,
        branch: String,
        isDirty: Bool?
    ) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        let probeKey = WorkspaceGitProbeKey(workspaceId: tabId, panelId: surfaceId)
        guard sidebarGitMetadataWatchEnabled else {
            clearWorkspaceGitMetadata(for: probeKey)
            return
        }
        let current = tab.panelGitBranches[surfaceId]
        let normalizedBranch = Self.normalizedBranchName(branch) ?? branch
        let nextIsDirty = isDirty ?? (current?.branch == normalizedBranch ? current?.isDirty ?? false : false)
        guard current?.branch != normalizedBranch || current?.isDirty != nextIsDirty else { return }
        tab.updatePanelGitBranch(panelId: surfaceId, branch: normalizedBranch, isDirty: nextIsDirty)
        if let directory = gitProbeDirectory(for: tab, panelId: surfaceId) {
            workspaceGitTrackedDirectoryByKey[probeKey] = directory
            updateWorkspaceGitMetadataWatcher(for: probeKey, directory: directory)
            updateWorkspaceGitMetadataFallbackTimer()
        }
        scheduleWorkspacePullRequestRefresh(
            workspaceId: tabId,
            panelId: surfaceId,
            reason: "branchChange"
        )
        scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: tabId,
            panelId: surfaceId,
            reason: "branchChange"
        )
    }

    func clearSurfaceGitBranch(tabId: UUID, surfaceId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        let hadBranch = tab.panelGitBranches[surfaceId] != nil
        let hadPullRequest = tab.panelPullRequests[surfaceId] != nil
        guard hadBranch || hadPullRequest else { return }
        clearWorkspacePullRequestTracking(
            for: WorkspaceGitProbeKey(workspaceId: tabId, panelId: surfaceId)
        )
        let probeKey = WorkspaceGitProbeKey(workspaceId: tabId, panelId: surfaceId)
        workspaceGitTrackedDirectoryByKey.removeValue(forKey: probeKey)
        stopWorkspaceGitMetadataWatcher(for: probeKey)
        updateWorkspaceGitMetadataFallbackTimer()
        tab.clearPanelGitBranch(panelId: surfaceId)
        tab.clearPanelPullRequest(panelId: surfaceId)
        scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: tabId,
            panelId: surfaceId,
            reason: "branchCleared"
        )
    }

    func updateSurfaceShellActivity(
        tabId: UUID,
        surfaceId: UUID,
        state: Workspace.PanelShellActivityState
    ) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        tab.updatePanelShellActivityState(panelId: surfaceId, state: state)
        if state == .promptIdle {
            scheduleWorkspacePullRequestRefresh(
                workspaceId: tabId,
                panelId: surfaceId,
                reason: "shellPrompt"
            )
        }
    }

    func handleWorkspacePullRequestCommandHint(
        tabId: UUID,
        surfaceId: UUID,
        action: String,
        target: String?
    ) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        reconcileLocalPullRequestActionIfPossible(
            workspace: tab,
            panelId: surfaceId,
            action: action,
            target: target
        )
        scheduleWorkspacePullRequestRefresh(
            workspaceId: tabId,
            panelId: surfaceId,
            reason: "commandHint:\(action)"
        )
    }

    private func reconcileLocalPullRequestActionIfPossible(
        workspace: Workspace,
        panelId: UUID,
        action: String,
        target: String?
    ) {
        guard let currentPullRequest = workspace.panelPullRequests[panelId],
              pullRequestCommandTargetMatchesCurrentPullRequest(
                target,
                currentPullRequest: currentPullRequest
              ) else {
            return
        }

        let nextStatus: SidebarPullRequestStatus
        switch action {
        case "merge":
            guard currentPullRequest.status == .open else { return }
            nextStatus = .merged
        case "close":
            guard currentPullRequest.status == .open else { return }
            nextStatus = .closed
        case "reopen":
            guard currentPullRequest.status != .open else { return }
            nextStatus = .open
        default:
            return
        }

        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: currentPullRequest.number,
            label: currentPullRequest.label,
            url: currentPullRequest.url,
            status: nextStatus,
            branch: currentPullRequest.branch,
            isStale: false
        )
    }

    private func pullRequestCommandTargetMatchesCurrentPullRequest(
        _ rawTarget: String?,
        currentPullRequest: SidebarPullRequestState
    ) -> Bool {
        let trimmedTarget = rawTarget?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedTarget.isEmpty else { return true }

        let numberToken = trimmedTarget.hasPrefix("#") ? String(trimmedTarget.dropFirst()) : trimmedTarget
        if let number = Int(numberToken), number == currentPullRequest.number {
            return true
        }

        if let targetURL = URL(string: trimmedTarget) {
            if targetURL == currentPullRequest.url {
                return true
            }
            if let lastComponent = targetURL.pathComponents.last,
               let number = Int(lastComponent),
               number == currentPullRequest.number {
                return true
            }
        }

        if Self.normalizedBranchName(trimmedTarget) == Self.normalizedBranchName(currentPullRequest.branch) {
            return true
        }

        return false
    }

    private func normalizeDirectory(_ directory: String) -> String {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return directory }
        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed) {
            if !url.path.isEmpty {
                return url.path
            }
        }
        return trimmed
    }

    func closeWorkspace(_ workspace: Workspace, recordHistory: Bool = true) {
        guard tabs.count > 1 else { return }
        sentryBreadcrumb("workspace.close", data: ["tabCount": tabs.count - 1])
        if recordHistory,
           workspace.isRestorableInSessionSnapshot,
           let index = tabs.firstIndex(where: { $0.id == workspace.id }) {
            let snapshot = workspace.sessionSnapshot(
                includeScrollback: true,
                restorableAgentIndex: RestorableAgentSessionIndex.load()
            )
            ClosedItemHistoryStore.shared.push(.workspace(ClosedWorkspaceHistoryEntry(
                workspaceId: workspace.id,
                windowId: AppDelegate.shared?.windowId(for: self),
                workspaceIndex: index,
                snapshot: snapshot
            )))
        }
        clearWorkspaceGitProbes(workspaceId: workspace.id)
        clearWorkspacePullRequestTracking(workspaceId: workspace.id)
        sidebarSelectedWorkspaceIds.remove(workspace.id)
        invalidateFocusHistoryTarget(workspaceId: workspace.id, panelId: nil)

        AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: workspace.id)
        workspace.withClosedPanelHistorySuppressed {
            workspace.teardownAllPanels()
        }
        workspace.teardownRemoteConnection()
        unwireClosedBrowserTracking(for: workspace)
        workspace.owningTabManager = nil

        if let index = tabs.firstIndex(where: { $0.id == workspace.id }) {
            tabs.remove(at: index)

            if selectedTabId == workspace.id {
                // Keep the "focused index" stable when possible:
                // - If we closed workspace i and there is still a workspace at index i, focus it (the one that moved up).
                // - Otherwise (we closed the last workspace), focus the new last workspace (i-1).
                let newIndex = min(index, max(0, tabs.count - 1))
                selectedTabId = tabs[newIndex].id
            }
        }
        publishCmuxWorkspaceClosed(workspace)
    }

    /// Detach a workspace from this window without closing its panels.
    /// Used by the socket API for cross-window moves.
    @discardableResult
    func detachWorkspace(tabId: UUID) -> Workspace? {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return nil }
        clearWorkspaceGitProbes(workspaceId: tabId)
        sidebarSelectedWorkspaceIds.remove(tabId)
        invalidateFocusHistoryTarget(workspaceId: tabId, panelId: nil)

        let removed = tabs.remove(at: index)
        unwireClosedBrowserTracking(for: removed)
        removed.owningTabManager = nil
        lastFocusedPanelByTab.removeValue(forKey: removed.id)

        if tabs.isEmpty {
            // The UI assumes each window always has at least one workspace.
            _ = addWorkspace()
            return removed
        }

        if selectedTabId == removed.id {
            let nextIndex = min(index, max(0, tabs.count - 1))
            selectedTabId = tabs[nextIndex].id
        }

        return removed
    }

    /// Attach an existing workspace to this window.
    func attachWorkspace(_ workspace: Workspace, at index: Int? = nil, select: Bool = true) {
        workspace.owningTabManager = self
        wireClosedBrowserTracking(for: workspace)
        let insertIndex: Int = {
            guard let index else { return tabs.count }
            return max(0, min(index, tabs.count))
        }()
        tabs.insert(workspace, at: insertIndex)
        if select {
            selectedTabId = workspace.id
        }
    }

    // Keep closeTab as convenience alias
    func closeTab(_ tab: Workspace) { closeWorkspace(tab) }
    func closeCurrentTabWithConfirmation() { closeCurrentWorkspaceWithConfirmation() }

    func closeCurrentWorkspace() {
        guard let selectedId = selectedTabId,
              let workspace = tabs.first(where: { $0.id == selectedId }) else { return }
        closeWorkspace(workspace)
    }

    func closeCurrentPanelWithConfirmation() {
#if DEBUG
        UITestRecorder.incrementInt("closePanelInvocations")
#endif
        guard !closeConfirmationInFlight else { return }
        guard let selectedId = selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedId }) else { return }
        reconcileFocusedPanelFromFirstResponderForKeyboard()
        guard let focusedPanelId = shortcutCloseTargetPanelId(in: tab) else { return }
        closePanelWithConfirmation(tab: tab, panelId: focusedPanelId)
    }

    func canCloseOtherTabsInFocusedPane() -> Bool {
        closeOtherTabsInFocusedPanePlan() != nil
    }

    func closeOtherTabsInFocusedPaneWithConfirmation() {
        guard !closeConfirmationInFlight else { return }
        guard let plan = closeOtherTabsInFocusedPanePlan() else { return }

        if CloseTabConfirmationPolicy.shouldConfirm(requiresConfirmation: true, source: .shortcut) {
            let prompt = CloseOtherTabsConfirmationPrompt(titles: plan.titles)
            guard confirmClose(
                title: prompt.title,
                message: prompt.message,
                acceptCmdD: false
            ) else { return }
        }

        for panelId in plan.panelIds {
            plan.workspace.markCloseHistoryEligible(panelId: panelId)
            _ = plan.workspace.closePanel(panelId, force: true)
        }
    }

    func closeCurrentWorkspaceWithConfirmation() {
#if DEBUG
        UITestRecorder.incrementInt("closeTabInvocations")
#endif
        guard !closeConfirmationInFlight else { return }
        let sidebarSelectionIds = orderedSidebarSelectedWorkspaceIds()
        if sidebarSelectionIds.count > 1 {
            closeWorkspacesWithConfirmation(sidebarSelectionIds, allowPinned: true)
            return
        }
        guard let selectedId = selectedTabId,
              let workspace = tabs.first(where: { $0.id == selectedId }) else { return }
        closeWorkspaceWithConfirmation(workspace)
    }

    func canCloseWorkspace(_ workspace: Workspace, allowPinned: Bool = false) -> Bool {
        allowPinned || !workspace.isPinned
    }

    @discardableResult
    func closeWorkspaceWithConfirmation(_ workspace: Workspace) -> Bool {
        if workspace.isPinned {
            guard confirmPinnedWorkspaceClose(source: .workspace) else { return false }
            closeWorkspaceIfRunningProcess(workspace, requiresConfirmation: false)
            return true
        }
        closeWorkspaceIfRunningProcess(workspace)
        return true
    }

    @discardableResult
    func closeWorkspaceFromCloseTabGesture(_ workspace: Workspace) -> Bool {
        if workspace.isPinned {
            guard confirmPinnedWorkspaceClose(source: .tabClose) else { return false }
            closeWorkspaceIfRunningProcess(workspace, requiresConfirmation: false)
            return true
        }
        closeWorkspaceIfRunningProcess(workspace, source: .tabClose)
        return true
    }

    @discardableResult
    func closeWorkspaceFromTabCloseButton(_ workspace: Workspace) -> Bool {
        if workspace.isPinned {
            guard confirmPinnedWorkspaceClose(source: .tabCloseButton) else { return false }
            closeWorkspaceIfRunningProcess(workspace, requiresConfirmation: false)
            return true
        }
        closeWorkspaceIfRunningProcess(workspace, source: .tabCloseButton)
        return true
    }

    @discardableResult
    func closeWorkspaceWithConfirmation(tabId: UUID) -> Bool {
        guard let workspace = tabs.first(where: { $0.id == tabId }) else { return false }
        return closeWorkspaceWithConfirmation(workspace)
    }

    func setSidebarSelectedWorkspaceIds(_ workspaceIds: Set<UUID>) {
        let existingIds = Set(tabs.map(\.id))
        sidebarSelectedWorkspaceIds = workspaceIds.intersection(existingIds)
    }

    func closeWorkspacesWithConfirmation(_ workspaceIds: [UUID], allowPinned: Bool) {
        let workspaces = orderedClosableWorkspaces(workspaceIds, allowPinned: allowPinned)
        guard !workspaces.isEmpty else { return }
        guard workspaces.count > 1 else {
            closeWorkspaceFromCloseTabGesture(workspaces[0])
            return
        }

        let plan = closeWorkspacesPlan(for: workspaces)
        if shouldConfirmClose(requiresConfirmation: true, source: .tabClose) {
            guard confirmClose(
                title: plan.title,
                message: plan.message,
                acceptCmdD: plan.acceptCmdD
            ) else { return }
        }

        if plan.workspaces.count == tabs.count,
           let firstWorkspace = plan.workspaces.first {
            if let window {
                window.performClose(nil)
                return
            }
            if AppDelegate.shared != nil {
                AppDelegate.shared?.closeMainWindowContainingTabId(firstWorkspace.id)
                return
            }
        }

        for workspace in plan.workspaces {
            guard tabs.contains(where: { $0.id == workspace.id }) else { continue }
            closeWorkspaceIfRunningProcess(workspace, requiresConfirmation: false)
        }
    }

    func selectWorkspace(_ workspace: Workspace) {
#if DEBUG
        debugPrimeWorkspaceSwitchTrigger("select", to: workspace.id)
#endif
        selectWorkspaceId(workspace.id, notificationDismissalContext: .explicitWorkspaceResume)
    }

    // Keep selectTab as convenience alias
    func selectTab(_ tab: Workspace) { selectWorkspace(tab) }

    var isCloseConfirmationInFlight: Bool { closeConfirmationInFlight }

    func beginCloseConfirmationSession() -> Bool {
        guard !closeConfirmationInFlight else { return false }
        closeConfirmationInFlight = true
        return true
    }

    func endCloseConfirmationSession() {
        DispatchQueue.main.async { [weak self] in
            self?.closeConfirmationInFlight = false
        }
    }

    func confirmClose(title: String, message: String, acceptCmdD: Bool) -> Bool {
        guard beginCloseConfirmationSession() else { return false }
        defer { endCloseConfirmationSession() }

        if let confirmCloseHandler {
            return confirmCloseHandler(title, message, acceptCmdD)
        }
        _ = acceptCmdD

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "dialog.closeTab.close", defaultValue: "Close"))
        alert.addButton(withTitle: String(localized: "dialog.closeTab.cancel", defaultValue: "Cancel"))

        if let closeButton = alert.buttons.first {
            closeButton.keyEquivalent = "\r"
            closeButton.keyEquivalentModifierMask = []
            alert.window.defaultButtonCell = closeButton.cell as? NSButtonCell
            alert.window.initialFirstResponder = closeButton
        }
        if let cancelButton = alert.buttons.dropFirst().first {
            cancelButton.keyEquivalent = "\u{1b}"
        }

        #if DEBUG
        UITestRecorder.record([
            "closeConfirmationTitle": title,
            "closeConfirmationMessage": message,
        ])
        #endif

        return runCloseConfirmationAlert(alert) == .alertFirstButtonReturn
    }

    private func runCloseConfirmationAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        if NSApp.activationPolicy() == .regular {
            NSApp.activate(ignoringOtherApps: true)
        }

        let presentingWindow = closeConfirmationPresentingWindow()
        let hasAttachedSheet = presentingWindow?.attachedSheet != nil
        guard let presentingWindow, !hasAttachedSheet else {
            #if DEBUG
            UITestRecorder.record([
                "closeConfirmationPresentation": "appModal",
                "closeConfirmationAttachedSheet": hasAttachedSheet ? "1" : "0",
            ])
            #endif

            return alert.runModal()
        }

        alert.beginSheetModal(for: presentingWindow) { result in
            NSApp.stopModal(withCode: result)
        }
        #if DEBUG
        DispatchQueue.main.async {
            UITestRecorder.record([
                "closeConfirmationPresentation": "sheet",
                "closeConfirmationAttachedSheet": presentingWindow.attachedSheet == nil ? "0" : "1",
            ])
        }
        #endif
        return NSApp.runModal(for: alert.window)
    }

    private func closeConfirmationPresentingWindow() -> NSWindow? {
        if let window, window.isVisible, isCloseConfirmationMainWindow(window) {
            return window
        }
        if let keyWindow = NSApp.keyWindow, keyWindow.isVisible, isCloseConfirmationMainWindow(keyWindow) {
            return keyWindow
        }
        if let mainWindow = NSApp.mainWindow, mainWindow.isVisible, isCloseConfirmationMainWindow(mainWindow) {
            return mainWindow
        }
        return NSApp.windows.first { candidate in
            candidate.isVisible && isCloseConfirmationMainWindow(candidate)
        }
    }

    private func isCloseConfirmationMainWindow(_ candidate: NSWindow) -> Bool {
        guard let raw = candidate.identifier?.rawValue else { return false }
        return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
    }

    private struct CloseOtherTabsInFocusedPanePlan {
        let workspace: Workspace
        let panelIds: [UUID]
        let titles: [String]
    }

    private struct CloseWorkspacesPlan {
        let workspaces: [Workspace]
        let title: String
        let message: String
        let acceptCmdD: Bool
    }

    private enum CloseConfirmationSource {
        case workspace
        case tabClose
        case tabCloseButton
    }

    private func closeOtherTabsInFocusedPanePlan() -> CloseOtherTabsInFocusedPanePlan? {
        guard let workspace = selectedWorkspace else { return nil }
        guard let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
            return nil
        }

        let tabsInPane = workspace.bonsplitController.tabs(inPane: paneId)
        guard !tabsInPane.isEmpty else { return nil }
        guard let selectedTabId = workspace.bonsplitController.selectedTab(inPane: paneId)?.id ?? tabsInPane.first?.id else {
            return nil
        }

        var targetPanelIds: [UUID] = []
        var targetTitles: [String] = []
        for tab in tabsInPane where tab.id != selectedTabId {
            guard let panelId = workspace.panelIdFromSurfaceId(tab.id) else { continue }
            if workspace.isPanelPinned(panelId) {
                continue
            }
            targetPanelIds.append(panelId)
            targetTitles.append(CloseOtherTabsConfirmationPrompt.displayTitle(workspace.panelTitle(panelId: panelId)))
        }

        guard !targetPanelIds.isEmpty else { return nil }
        return CloseOtherTabsInFocusedPanePlan(
            workspace: workspace,
            panelIds: targetPanelIds,
            titles: targetTitles
        )
    }

    private func orderedClosableWorkspaces(_ workspaceIds: [UUID], allowPinned: Bool) -> [Workspace] {
        let targetIds = Set(workspaceIds)
        return tabs.compactMap { workspace in
            guard targetIds.contains(workspace.id) else { return nil }
            guard allowPinned || !workspace.isPinned else { return nil }
            return workspace
        }
    }

    private func orderedSidebarSelectedWorkspaceIds() -> [UUID] {
        tabs.compactMap { workspace in
            sidebarSelectedWorkspaceIds.contains(workspace.id) ? workspace.id : nil
        }
    }

    private func closeWorkspacesPlan(for workspaces: [Workspace]) -> CloseWorkspacesPlan {
        let willCloseWindow = workspaces.count == tabs.count
        let title = willCloseWindow
            ? String(localized: "dialog.closeWindow.title", defaultValue: "Close window?")
            : String(localized: "dialog.closeWorkspaces.title", defaultValue: "Close workspaces?")
        let titleLines = workspaces
            .map { "• \(closeWorkspaceDisplayTitle($0.title))" }
            .joined(separator: "\n")
        let format = willCloseWindow
            ? String(
                localized: "dialog.closeWorkspacesWindow.message",
                defaultValue: "This will close the current window, its %1$lld workspaces, and all of their panels:\n%2$@"
            )
            : String(
                localized: "dialog.closeWorkspaces.message",
                defaultValue: "This will close %1$lld workspaces and all of their panels:\n%2$@"
            )
        let message = String(format: format, locale: .current, Int64(workspaces.count), titleLines)
        return CloseWorkspacesPlan(
            workspaces: workspaces,
            title: title,
            message: message,
            acceptCmdD: willCloseWindow
        )
    }

    private func closeWorkspaceDisplayTitle(_ title: String?) -> String {
        let collapsed = title?
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let collapsed, !collapsed.isEmpty {
            return collapsed
        }
        return String(localized: "workspace.displayName.fallback", defaultValue: "Workspace")
    }

    private func closeWorkspaceIfRunningProcess(
        _ workspace: Workspace,
        requiresConfirmation: Bool = true,
        source: CloseConfirmationSource = .workspace
    ) {
        let willCloseWindow = tabs.count <= 1
        let needsCloseConfirmation = workspaceNeedsConfirmClose(workspace)
        if requiresConfirmation,
           shouldConfirmClose(requiresConfirmation: needsCloseConfirmation, source: source),
           !confirmClose(
               title: String(localized: "dialog.closeWorkspace.title", defaultValue: "Close workspace?"),
               message: String(localized: "dialog.closeWorkspace.message", defaultValue: "This will close the workspace and all of its panels."),
               acceptCmdD: willCloseWindow
           ) {
            return
        }
        if tabs.count <= 1 {
            // Last workspace in this window: match Close Workspace shortcut behavior.
            if let window {
                window.performClose(nil)
            } else {
                AppDelegate.shared?.closeMainWindowContainingTabId(workspace.id)
            }
        } else {
            closeWorkspace(workspace)
        }
    }

    private func shouldConfirmClose(requiresConfirmation: Bool, source: CloseConfirmationSource) -> Bool {
        switch source {
        case .workspace:
            return requiresConfirmation
        case .tabClose:
            return CloseTabConfirmationPolicy.shouldConfirm(
                requiresConfirmation: requiresConfirmation,
                source: .shortcut
            )
        case .tabCloseButton:
            return CloseTabConfirmationPolicy.shouldConfirm(
                requiresConfirmation: requiresConfirmation,
                source: .tabCloseButton
            )
        }
    }

    private func confirmPinnedWorkspaceClose(source: CloseConfirmationSource) -> Bool {
        guard shouldConfirmClose(requiresConfirmation: true, source: source) else { return true }
        return confirmClose(
            title: String(localized: "dialog.closePinnedWorkspace.title", defaultValue: "Close pinned workspace?"),
            message: String(
                localized: "dialog.closePinnedWorkspace.message",
                defaultValue: "This workspace is pinned. Closing it will close the workspace and all of its panels."
            ),
            acceptCmdD: tabs.count <= 1
        )
    }

    private func shouldCloseWorkspaceOnLastSurfaceShortcut(_ workspace: Workspace, panelId: UUID) -> Bool {
        LastSurfaceCloseShortcutSettings.closesWorkspace() &&
            workspace.panels.count <= 1 &&
            workspace.panels[panelId] != nil
    }

    private func closePanelWithConfirmation(tab: Workspace, panelId: UUID) {
        guard tab.panels[panelId] != nil else {
#if DEBUG
            cmuxDebugLog(
                "surface.close.shortcut.skip tab=\(tab.id.uuidString.prefix(5)) " +
                "panel=\(panelId.uuidString.prefix(5)) reason=missingPanel"
            )
#endif
            return
        }

        let bonsplitTabCount = tab.bonsplitController.allPaneIds.reduce(0) { partial, paneId in
            partial + tab.bonsplitController.tabs(inPane: paneId).count
        }
        let panelKind: String = {
            guard let panel = tab.panels[panelId] else { return "missing" }
            if panel is TerminalPanel { return "terminal" }
            if panel is BrowserPanel { return "browser" }
            return String(describing: type(of: panel))
        }()
        let closesWorkspaceOnLastSurfaceShortcut = shouldCloseWorkspaceOnLastSurfaceShortcut(tab, panelId: panelId)
#if DEBUG
        cmuxDebugLog(
            "surface.close.shortcut.begin tab=\(tab.id.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) kind=\(panelKind) " +
            "panelCount=\(tab.panels.count) bonsplitTabs=\(bonsplitTabCount) " +
            "closeWorkspaceOnLastSurface=\(closesWorkspaceOnLastSurfaceShortcut ? 1 : 0)"
        )
#endif

        // The last-surface shortcut preference only affects the Close Tab shortcut path.
        // The tab close button continues to use Workspace's explicit-close path when it
        // closes the last surface.
        if closesWorkspaceOnLastSurfaceShortcut,
           let surfaceId = tab.surfaceIdFromPanelId(panelId) {
            tab.markExplicitClose(surfaceId: surfaceId)
        }
        tab.markCloseHistoryEligible(panelId: panelId)
        let closed = tab.closePanel(panelId)
#if DEBUG
        cmuxDebugLog(
            "surface.close.shortcut tab=\(tab.id.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) closed=\(closed ? 1 : 0) " +
            "panelsAfterCall=\(tab.panels.count)"
        )
#endif
    }

    private func shortcutCloseTargetPanelId(in workspace: Workspace) -> UUID? {
        if let focusedPanelId = workspace.focusedPanelId,
           workspace.panels[focusedPanelId] != nil {
            return focusedPanelId
        }

        if workspace.panels.count == 1 {
            return workspace.panels.keys.first
        }

        let candidatePane = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first
        if let candidatePane,
           let selectedTabId = workspace.bonsplitController.selectedTab(inPane: candidatePane)?.id
                ?? workspace.bonsplitController.tabs(inPane: candidatePane).first?.id,
           let panelId = workspace.panelIdFromSurfaceId(selectedTabId),
           workspace.panels[panelId] != nil {
            return panelId
        }

        return nil
    }

    func closePanelWithConfirmation(tabId: UUID, surfaceId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        closePanelWithConfirmation(tab: tab, panelId: surfaceId)
    }

    /// Runtime close requests from Ghostty should only ever target the specific surface.
    /// They must not escalate into workspace/window-close semantics for "last tab".
    func closeRuntimeSurfaceWithConfirmation(tabId: UUID, surfaceId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        guard tab.panels[surfaceId] != nil else { return }

        let requiresConfirmation: Bool
        if let terminalPanel = tab.terminalPanel(for: surfaceId),
           tab.panelNeedsConfirmClose(panelId: surfaceId, fallbackNeedsConfirmClose: terminalPanel.needsConfirmClose()) {
            requiresConfirmation = true
        } else {
            requiresConfirmation = false
        }

        if CloseTabConfirmationPolicy.shouldConfirm(
            requiresConfirmation: requiresConfirmation,
            source: .shortcut
        ) {
            guard confirmClose(
                title: String(localized: "dialog.closeTab.title", defaultValue: "Close tab?"),
                message: String(localized: "dialog.closeTab.message", defaultValue: "This will close the current tab."),
                acceptCmdD: false
            ) else { return }
        }

        _ = tab.closePanel(surfaceId, force: true)
        AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: tab.id, surfaceId: surfaceId)
    }

    /// Runtime close requests from Ghostty without confirmation (e.g. child-exit).
    /// This path must only close the addressed surface and must never close the workspace window.
    func closeRuntimeSurface(tabId: UUID, surfaceId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        guard tab.panels[surfaceId] != nil else { return }

#if DEBUG
        cmuxDebugLog(
            "surface.close.runtime tab=\(tabId.uuidString.prefix(5)) " +
            "surface=\(surfaceId.uuidString.prefix(5)) panelsBefore=\(tab.panels.count)"
        )
#endif

        // Keep AppKit first responder in sync with workspace focus before routing the close.
        // If split reparenting caused a temporary model/view mismatch, fallback close logic in
        // Workspace.closePanel uses focused selection to resolve the correct tab deterministically.
        reconcileFocusedPanelFromFirstResponderForKeyboard()
        let closed = tab.closePanel(surfaceId, force: true)
#if DEBUG
        cmuxDebugLog(
            "surface.close.runtime.done tab=\(tabId.uuidString.prefix(5)) " +
            "surface=\(surfaceId.uuidString.prefix(5)) closed=\(closed ? 1 : 0) panelsAfter=\(tab.panels.count)"
        )
#endif
        AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: tab.id, surfaceId: surfaceId)
    }

    /// Close a panel because its child process exited (e.g. the user hit Ctrl+D).
    ///
    /// This should never prompt: the process is already gone, and Ghostty emits the
    /// `SHOW_CHILD_EXITED` action specifically so the host app can decide what to do.
    func closePanelAfterChildExited(tabId: UUID, surfaceId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        guard tab.panels[surfaceId] != nil else { return }
        let keepsRemoteWorkspaceOpen =
            tab.panels.count <= 1 && tab.shouldDemoteWorkspaceAfterChildExit(surfaceId: surfaceId)

#if DEBUG
        cmuxDebugLog(
            "surface.close.childExited tab=\(tabId.uuidString.prefix(5)) " +
            "surface=\(surfaceId.uuidString.prefix(5)) panels=\(tab.panels.count) workspaces=\(tabs.count) " +
            "remoteWorkspace=\(tab.isRemoteWorkspace ? 1 : 0) keepRemote=\(keepsRemoteWorkspaceOpen ? 1 : 0)"
        )
#endif

        // Exiting the last SSH surface should demote the workspace back to a local one.
        // Route through Workspace close handling so remote teardown and replacement-panel
        // logic run before TabManager considers removing the workspace itself, including
        // session-end paths where remote configuration was cleared before Ghostty delivered
        // the child-exit callback.
        if keepsRemoteWorkspaceOpen {
            closeRuntimeSurface(tabId: tabId, surfaceId: surfaceId)
            return
        }

        // Child-exit on the last panel should collapse the workspace, matching explicit close
        // semantics (and close the window when it was the last workspace).
        if tab.panels.count <= 1 {
            if tabs.count <= 1 {
                if let app = AppDelegate.shared {
                    app.notificationStore?.clearNotifications(forTabId: tabId)
                    app.closeMainWindowContainingTabId(tabId, recordHistory: false)
                } else {
                    // Headless/test fallback when no AppDelegate window context exists.
                    closeRuntimeSurface(tabId: tabId, surfaceId: surfaceId)
                }
            } else {
                closeWorkspace(tab, recordHistory: false)
            }
            return
        }

        closeRuntimeSurface(tabId: tabId, surfaceId: surfaceId)
    }

    private func workspaceNeedsConfirmClose(_ workspace: Workspace) -> Bool {
#if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_FORCE_CONFIRM_CLOSE_WORKSPACE"] == "1" {
            return true
        }
#endif
        return workspace.needsConfirmClose()
    }

    func titleForTab(_ tabId: UUID) -> String? {
        tabs.first(where: { $0.id == tabId })?.title
    }

    // MARK: - Panel/Surface ID Access

    /// Returns the focused panel ID for a tab (replaces focusedSurfaceId)
    func focusedPanelId(for tabId: UUID) -> UUID? {
        tabs.first(where: { $0.id == tabId })?.focusedPanelId
    }

    /// Returns the focused panel if it's a BrowserPanel, nil otherwise
    var focusedBrowserPanel: BrowserPanel? {
        guard let tab = selectedWorkspace,
              let panelId = tab.focusedPanelId else { return nil }
        return tab.panels[panelId] as? BrowserPanel
    }

    @discardableResult
    func zoomInFocusedBrowser() -> Bool {
        focusedBrowserPanel?.zoomIn() ?? false
    }

    @discardableResult
    func zoomOutFocusedBrowser() -> Bool {
        focusedBrowserPanel?.zoomOut() ?? false
    }

    @discardableResult
    func resetZoomFocusedBrowser() -> Bool {
        focusedBrowserPanel?.resetZoom() ?? false
    }

    @discardableResult
    func toggleDeveloperToolsFocusedBrowser() -> Bool {
        focusedBrowserPanel?.toggleDeveloperTools() ?? false
    }

    @discardableResult
    func showJavaScriptConsoleFocusedBrowser() -> Bool {
        focusedBrowserPanel?.showDeveloperToolsConsole() ?? false
    }

    @discardableResult
    func toggleReactGrabFromCurrentFocus() -> Bool {
        guard let workspace = selectedWorkspace else { return false }

        let snapshots = workspace.panels.values.map { panel in
            ReactGrabShortcutPanelSnapshot(
                id: panel.id,
                panelType: panel.panelType,
                isFocused: panel.id == workspace.focusedPanelId
            )
        }
        guard let route = resolveReactGrabShortcutRoute(panels: snapshots),
              let browserPanel = workspace.browserPanel(for: route.browserPanelId) else {
            return false
        }

        if let returnTerminalPanelId = route.returnTerminalPanelId {
            browserPanel.armReactGrabRoundTrip(returnTo: returnTerminalPanelId)
        } else {
            browserPanel.clearReactGrabRoundTrip(reason: "shortcut.noReturnTarget")
        }

        if workspace.focusedPanelId != browserPanel.id {
            workspace.clearSplitZoom()
            workspace.focusPanel(browserPanel.id)
        }

        let didRequestExplicitWebViewFocus = browserPanel.requestExplicitWebViewFocus()
#if DEBUG
        cmuxDebugLog(
            "reactGrab.pasteback h1.focusRequestResult " +
            "workspace=\(workspace.id.uuidString.prefix(5)) " +
            "browser=\(browserPanel.id.uuidString.prefix(5)) " +
            "return=\(route.returnTerminalPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil") " +
            "success=\(didRequestExplicitWebViewFocus ? 1 : 0)"
        )
#endif

        Task { @MainActor [weak browserPanel] in
            guard let browserPanel else { return }
            if route.returnTerminalPanelId != nil {
                await browserPanel.ensureReactGrabActive()
            } else {
                await browserPanel.toggleOrInjectReactGrab()
            }
            if !didRequestExplicitWebViewFocus {
                _ = browserPanel.requestExplicitWebViewFocus()
            }
        }
        return true
    }

    /// Backwards compatibility: returns the focused surface ID
    func focusedSurfaceId(for tabId: UUID) -> UUID? {
        focusedPanelId(for: tabId)
    }

    func rememberFocusedSurface(tabId: UUID, surfaceId: UUID) {
        lastFocusedPanelByTab[tabId] = surfaceId
    }

    func applyWindowBackgroundForSelectedTab() {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }),
              let terminalPanel = tab.focusedTerminalPanel else { return }
        terminalPanel.applyWindowBackgroundIfActive()
    }

    func applyWindowBackdropModeForAllTabs(reason: String) {
        let backgroundColor = GhosttyApp.shared.defaultBackgroundColor
        let backgroundOpacity = GhosttyApp.shared.defaultBackgroundOpacity
        for tab in tabs {
            tab.applyGhosttyChrome(
                backgroundColor: backgroundColor,
                backgroundOpacity: backgroundOpacity,
                reason: reason
            )
        }
        applyWindowBackgroundForSelectedTab()
    }

    private func focusSelectedTabPanel(previousTabId: UUID?) {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }) else { return }

        let panelId: UUID
        if let restoredPanelId = lastFocusedPanelByTab[selectedTabId],
           tab.panels[restoredPanelId] != nil {
            panelId = restoredPanelId
        } else if let focusedPanelId = tab.focusedPanelId,
                  tab.panels[focusedPanelId] != nil {
            panelId = focusedPanelId
        } else {
            return
        }

        // Defer unfocusing the previous workspace's panel until ContentView confirms handoff
        // completion (new workspace has focus or timeout fallback), to avoid a visible freeze gap.
        if let previousTabId,
           let previousTab = tabs.first(where: { $0.id == previousTabId }),
           let previousPanelId = previousTab.focusedPanelId,
           previousTab.panels[previousPanelId] != nil {
            replacePendingWorkspaceUnfocusTarget(
                with: (tabId: previousTabId, panelId: previousPanelId)
            )
        }

        // Route workspace reactivation through the normal focus machinery so panel-local
        // activation intents like browser find-field focus are restored on return.
        tab.focusPanel(panelId)
    }

    func completePendingWorkspaceUnfocus(reason: String) {
        guard let pending = pendingWorkspaceUnfocusTarget else { return }
        // If this tab became selected again before handoff completion, drop the stale
        // pending entry so it cannot be flushed later and deactivate the selected workspace.
        guard Self.shouldUnfocusPendingWorkspace(
            pendingTabId: pending.tabId,
            selectedTabId: selectedTabId
        ) else {
            pendingWorkspaceUnfocusTarget = nil
#if DEBUG
            cmuxDebugLog(
                "ws.unfocus.drop tab=\(Self.debugShortWorkspaceId(pending.tabId)) panel=\(String(pending.panelId.uuidString.prefix(5))) reason=selected_again"
            )
#endif
            return
        }
        pendingWorkspaceUnfocusTarget = nil
        unfocusWorkspacePanel(tabId: pending.tabId, panelId: pending.panelId)
#if DEBUG
        if let snapshot = debugCurrentWorkspaceSwitchSnapshot() {
            let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
            cmuxDebugLog(
                "ws.unfocus.complete id=\(snapshot.id) dt=\(Self.debugMsText(dtMs)) " +
                "tab=\(Self.debugShortWorkspaceId(pending.tabId)) panel=\(String(pending.panelId.uuidString.prefix(5))) reason=\(reason)"
            )
        } else {
            cmuxDebugLog(
                "ws.unfocus.complete id=none tab=\(Self.debugShortWorkspaceId(pending.tabId)) " +
                "panel=\(String(pending.panelId.uuidString.prefix(5))) reason=\(reason)"
            )
        }
#endif
    }

    private func replacePendingWorkspaceUnfocusTarget(with next: (tabId: UUID, panelId: UUID)) {
        if let current = pendingWorkspaceUnfocusTarget,
           current.tabId == next.tabId,
           current.panelId == next.panelId {
            return
        }

        if let current = pendingWorkspaceUnfocusTarget {
            // Never unfocus the currently selected workspace when replacing stale pending state.
            if Self.shouldUnfocusPendingWorkspace(
                pendingTabId: current.tabId,
                selectedTabId: selectedTabId
            ) {
                unfocusWorkspacePanel(tabId: current.tabId, panelId: current.panelId)
#if DEBUG
                cmuxDebugLog(
                    "ws.unfocus.flush tab=\(Self.debugShortWorkspaceId(current.tabId)) panel=\(String(current.panelId.uuidString.prefix(5))) reason=replaced"
                )
#endif
            } else {
#if DEBUG
                cmuxDebugLog(
                    "ws.unfocus.drop tab=\(Self.debugShortWorkspaceId(current.tabId)) panel=\(String(current.panelId.uuidString.prefix(5))) reason=replaced_selected"
                )
#endif
            }
        }

        pendingWorkspaceUnfocusTarget = next
#if DEBUG
        if let snapshot = debugCurrentWorkspaceSwitchSnapshot() {
            let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
            cmuxDebugLog(
                "ws.unfocus.defer id=\(snapshot.id) dt=\(Self.debugMsText(dtMs)) " +
                "tab=\(Self.debugShortWorkspaceId(next.tabId)) panel=\(String(next.panelId.uuidString.prefix(5)))"
            )
        } else {
            cmuxDebugLog(
                "ws.unfocus.defer id=none tab=\(Self.debugShortWorkspaceId(next.tabId)) panel=\(String(next.panelId.uuidString.prefix(5)))"
            )
        }
#endif
    }

    private func unfocusWorkspacePanel(tabId: UUID, panelId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }),
              let panel = tab.panels[panelId] else { return }
        panel.unfocus()
    }

    static func shouldUnfocusPendingWorkspace(pendingTabId: UUID, selectedTabId: UUID?) -> Bool {
        selectedTabId != pendingTabId
    }

    private enum NotificationDismissalContext: Sendable {
        case activeFocus
        case explicitWorkspaceResume
        case directInteraction
        case terminalInteraction

        var requiresActiveApp: Bool {
            switch self {
            case .activeFocus, .explicitWorkspaceResume:
                return true
            case .directInteraction, .terminalInteraction:
                return false
            }
        }

        var canDismissManualUnreadIndicator: Bool {
            self == .terminalInteraction
        }

        // Generic active focus can be produced by restore/programmatic selection.
        // Keep this exhaustive so any future context must make an explicit
        // restored-unread policy decision.
        var canDismissRestoredUnreadIndicator: Bool {
            switch self {
            case .activeFocus:
                return false
            case .explicitWorkspaceResume, .directInteraction, .terminalInteraction:
                return true
            }
        }
    }

    private func selectWorkspaceId(
        _ tabId: UUID,
        notificationDismissalContext: NotificationDismissalContext?
    ) {
        guard selectedTabId != tabId else {
            pendingSelectedTabNotificationDismissContext = nil
            if let notificationDismissalContext {
                dismissFocusedPanelNotificationIfActive(tabId: tabId, context: notificationDismissalContext)
            }
            return
        }

        pendingSelectedTabNotificationDismissContext = notificationDismissalContext
        selectedTabId = tabId
    }

    private func dismissFocusedPanelNotificationIfActive(
        tabId: UUID,
        context: NotificationDismissalContext = .activeFocus
    ) {
        let shouldSuppressFlash = suppressFocusFlash
        suppressFocusFlash = false
        guard !shouldSuppressFlash else { return }
        guard let panelId = focusedPanelId(for: tabId) else { return }
        dismissPanelNotificationOnFocus(tabId: tabId, panelId: panelId, context: context)
    }

    private func dismissPanelNotificationOnFocus(tabId: UUID, panelId: UUID, explicitFocusIntent: Bool) {
        dismissPanelNotificationOnFocus(
            tabId: tabId,
            panelId: panelId,
            context: explicitFocusIntent ? .directInteraction : .activeFocus
        )
    }

    private func dismissPanelNotificationOnFocus(
        tabId: UUID,
        panelId: UUID,
        context: NotificationDismissalContext
    ) {
        guard selectedTabId == tabId else { return }
        guard !suppressFocusFlash else { return }
        _ = dismissNotification(
            tabId: tabId,
            surfaceId: panelId,
            context: context
        )
    }

    @discardableResult
    func dismissNotificationOnDirectInteraction(tabId: UUID, surfaceId: UUID?) -> Bool {
        dismissNotification(tabId: tabId, surfaceId: surfaceId, context: .directInteraction)
    }

    @discardableResult
    func dismissNotificationOnTerminalInteraction(tabId: UUID, surfaceId: UUID?) -> Bool {
        dismissNotification(tabId: tabId, surfaceId: surfaceId, context: .terminalInteraction)
    }

    @discardableResult
    private func dismissNotification(
        tabId: UUID,
        surfaceId: UUID?,
        context: NotificationDismissalContext
    ) -> Bool {
        guard selectedTabId == tabId else { return false }
        if context.requiresActiveApp {
            guard AppFocusState.isAppActive() else { return false }
        }
        guard let notificationStore = AppDelegate.shared?.notificationStore else { return false }
        let workspace = tabs.first(where: { $0.id == tabId })
        let targetPanelId = surfaceId.flatMap { surfaceOrPanelId in
            workspace.flatMap { panelId(forSurfaceOrPanelId: surfaceOrPanelId, in: $0) }
        }
        var notificationSurfaceIds: [UUID] = []
        if let surfaceId {
            notificationSurfaceIds.append(surfaceId)
        }
        if let targetPanelId, !notificationSurfaceIds.contains(targetPanelId) {
            notificationSurfaceIds.append(targetPanelId)
        }
        let hasManualPanelUnread = targetPanelId.map { workspace?.manualUnreadPanelIds.contains($0) ?? false } ?? false
        let hasRestoredPanelUnread = targetPanelId.map { workspace?.hasRestoredUnreadIndicator(panelId: $0) ?? false } ?? false
        let hasManualWorkspaceUnread = notificationStore.hasManualUnread(forTabId: tabId)
        let hasRestoredWorkspaceUnread = notificationStore.hasRestoredUnreadIndicator(forTabId: tabId)
        let canDismissManualUnreadIndicator = context.canDismissManualUnreadIndicator &&
            (hasManualPanelUnread || hasManualWorkspaceUnread)
        let canDismissRestoredUnreadIndicator = context.canDismissRestoredUnreadIndicator &&
            (hasRestoredPanelUnread || hasRestoredWorkspaceUnread)
        let canDismissUnreadIndicator = canDismissManualUnreadIndicator || canDismissRestoredUnreadIndicator
        let hasUnreadNotification: Bool
        let hasFocusedIndicator: Bool
        if notificationSurfaceIds.isEmpty {
            hasUnreadNotification = notificationStore.hasUnreadNotification(forTabId: tabId, surfaceId: nil)
            hasFocusedIndicator = notificationStore.hasVisibleNotificationIndicator(forTabId: tabId, surfaceId: nil)
        } else {
            hasUnreadNotification = notificationSurfaceIds.contains {
                notificationStore.hasUnreadNotification(forTabId: tabId, surfaceId: $0)
            }
            hasFocusedIndicator = notificationSurfaceIds.contains {
                notificationStore.hasVisibleNotificationIndicator(forTabId: tabId, surfaceId: $0)
            }
        }
        guard hasUnreadNotification || hasFocusedIndicator || canDismissUnreadIndicator else { return false }
        if hasUnreadNotification {
            if notificationSurfaceIds.isEmpty {
                notificationStore.markRead(forTabId: tabId, surfaceId: nil)
            } else {
                for surfaceId in notificationSurfaceIds {
                    notificationStore.markRead(forTabId: tabId, surfaceId: surfaceId)
                }
            }
        }
        var didDismissUnreadIndicator = false
        if context.canDismissManualUnreadIndicator {
            if let targetPanelId, hasManualPanelUnread {
                workspace?.clearManualUnread(panelId: targetPanelId)
                didDismissUnreadIndicator = true
            }
            if hasManualWorkspaceUnread {
                didDismissUnreadIndicator = notificationStore.clearManualUnread(forTabId: tabId) || didDismissUnreadIndicator
            }
        }
        if context.canDismissRestoredUnreadIndicator {
            if let targetPanelId, hasRestoredPanelUnread {
                workspace?.clearRestoredUnreadIndicator(panelId: targetPanelId)
                didDismissUnreadIndicator = true
            }
            if hasRestoredWorkspaceUnread {
                didDismissUnreadIndicator =
                    notificationStore.clearRestoredUnreadIndicator(forTabId: tabId) || didDismissUnreadIndicator
            }
        }
        if notificationSurfaceIds.isEmpty {
            notificationStore.clearFocusedReadIndicator(forTabId: tabId, surfaceId: nil)
        } else {
            for surfaceId in notificationSurfaceIds {
                notificationStore.clearFocusedReadIndicator(forTabId: tabId, surfaceId: surfaceId)
            }
        }
        if let targetPanelId,
           let workspace {
            if hasUnreadNotification || hasFocusedIndicator {
                workspace.triggerNotificationDismissFlash(panelId: targetPanelId)
            } else if didDismissUnreadIndicator {
                workspace.triggerUnreadIndicatorDismissFlash(panelId: targetPanelId)
            }
        }
        return true
    }

    private func enqueuePanelTitleUpdate(tabId: UUID, panelId: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
#if DEBUG
        cmuxDebugLog(
            "workspace.title.enqueue workspace=\(Self.debugShortWorkspaceId(tabId)) " +
            "panel=\(panelId.uuidString.prefix(5)) title=\"\(Self.debugTitlePreview(trimmed))\""
        )
#endif
        let key = PanelTitleUpdateKey(tabId: tabId, panelId: panelId)
        pendingPanelTitleUpdates[key] = trimmed
        panelTitleUpdateCoalescer.signal { [weak self] in
            self?.flushPendingPanelTitleUpdates()
        }
    }

    private func flushPendingPanelTitleUpdates() {
        guard !pendingPanelTitleUpdates.isEmpty else { return }
        let updates = pendingPanelTitleUpdates
        pendingPanelTitleUpdates.removeAll(keepingCapacity: true)
        for (key, title) in updates {
            updatePanelTitle(tabId: key.tabId, panelId: key.panelId, title: title)
        }
    }

    private func updatePanelTitle(tabId: UUID, panelId: UUID, title: String) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        _ = tab.updatePanelTitle(panelId: panelId, title: title)

        if tab.focusedPanelId == panelId {
            tab.applyProcessTitle(title)
            if selectedTabId == tabId {
                updateWindowTitle(for: tab)
            }
        }
    }

    func focusedSurfaceTitleDidChange(tabId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }),
              let focusedPanelId = tab.focusedPanelId,
              let title = tab.panelTitles[focusedPanelId] else { return }
        tab.applyProcessTitle(title)
        if selectedTabId == tabId {
            updateWindowTitle(for: tab)
        }
    }

    private func updateWindowTitleForSelectedTab() {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }) else {
            updateWindowTitle(for: nil)
            return
        }
        updateWindowTitle(for: tab)
    }

    private func updateWindowTitle(for tab: Workspace?) {
        let title = windowTitle(for: tab)
        guard let targetWindow = window else { return }
        targetWindow.title = title
    }

    private func windowTitle(for tab: Workspace?) -> String {
        guard let tab else { return "cmux" }
        let trimmedTitle = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }
        let trimmedDirectory = tab.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedDirectory.isEmpty ? "cmux" : trimmedDirectory
    }

    func focusTab(
        _ tabId: UUID,
        surfaceId: UUID? = nil,
        suppressFlash: Bool = false,
        focusIntent: PanelFocusIntent? = nil,
        dismissRestoredUnreadOnResume: Bool? = nil
    ) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        let targetPanelId = surfaceId.flatMap { panelId(forSurfaceOrPanelId: $0, in: tab) }
        if let targetPanelId {
            // Keep selected-surface intent stable across selectedTabId didSet async restore.
            lastFocusedPanelByTab[tabId] = targetPanelId
        }
        let shouldDismissRestoredUnread = dismissRestoredUnreadOnResume ?? !suppressFlash
        let dismissalContext: NotificationDismissalContext? = shouldDismissRestoredUnread ? .explicitWorkspaceResume : nil
        let shouldDeferSelectedWorkspaceDismissal =
            selectedTabId == tabId &&
            targetPanelId.map { $0 != focusedPanelId(for: tabId) } == true
#if DEBUG
        debugPrimeWorkspaceSwitchTrigger("focus", to: tabId)
#endif
        selectWorkspaceId(
            tabId,
            notificationDismissalContext: shouldDeferSelectedWorkspaceDismissal ? nil : dismissalContext
        )
        NotificationCenter.default.post(
            name: .ghosttyDidFocusTab,
            object: nil,
            userInfo: [GhosttyNotificationKey.tabId: tabId]
        )

        if let surfaceId {
            let focusPanelId = targetPanelId ?? surfaceId
            if !suppressFlash {
                focusSurface(tabId: tabId, surfaceId: focusPanelId)
            } else {
                tab.focusPanel(focusPanelId, focusIntent: focusIntent)
            }
            if let dismissalContext {
                _ = dismissNotification(tabId: tabId, surfaceId: surfaceId, context: dismissalContext)
            }
        }
    }

    @discardableResult
    func focusTabFromNotification(_ tabId: UUID, surfaceId: UUID? = nil) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else {
#if DEBUG
            cmuxDebugLog("notification.focus.fail tab=\(tabId.uuidString.prefix(5)) reason=missingTab")
#endif
            return false
        }
        if let surfaceId, tab.panels[surfaceId] == nil {
#if DEBUG
            cmuxDebugLog(
                "notification.focus.fail tab=\(tabId.uuidString.prefix(5)) " +
                "panel=\(surfaceId.uuidString.prefix(5)) reason=missingPanel"
            )
#endif
            return false
        }
        let desiredPanelId = surfaceId ?? tab.focusedPanelId
#if DEBUG
        if let desiredPanelId {
            AppDelegate.shared?.armJumpUnreadFocusRecord(tabId: tabId, surfaceId: desiredPanelId)
        }
#endif
        // Jump-to-unread should reveal the destination pane instead of keeping an old split-zoom
        // state active around it.
        tab.clearSplitZoom()
        suppressFocusFlash = true
        focusTab(tabId, surfaceId: desiredPanelId, suppressFlash: true)
        suppressFocusFlash = false

        if let targetPanelId = desiredPanelId ?? tab.focusedPanelId,
           tab.panels[targetPanelId] != nil {
            _ = dismissNotificationOnDirectInteraction(tabId: tabId, surfaceId: targetPanelId)
        }
        return true
    }

    func focusSurface(tabId: UUID, surfaceId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        tab.focusPanel(panelId(forSurfaceOrPanelId: surfaceId, in: tab) ?? surfaceId)
    }

    private func panelId(forSurfaceOrPanelId surfaceOrPanelId: UUID, in workspace: Workspace) -> UUID? {
        if workspace.panels[surfaceOrPanelId] != nil {
            return surfaceOrPanelId
        }
        return workspace.panelIdFromSurfaceId(TabID(uuid: surfaceOrPanelId))
    }

    func selectNextTab() {
        guard let currentId = selectedTabId,
              let currentIndex = tabs.firstIndex(where: { $0.id == currentId }) else { return }
        let nextIndex = (currentIndex + 1) % tabs.count
#if DEBUG
        let nextId = tabs[nextIndex].id
        debugPrepareWorkspaceSwitch("next", from: currentId, to: nextId)
#endif
        activateWorkspaceCycleHotWindow()
        selectWorkspaceId(
            tabs[nextIndex].id,
            notificationDismissalContext: .explicitWorkspaceResume
        )
    }

    func selectPreviousTab() {
        guard let currentId = selectedTabId,
              let currentIndex = tabs.firstIndex(where: { $0.id == currentId }) else { return }
        let prevIndex = (currentIndex - 1 + tabs.count) % tabs.count
#if DEBUG
        let prevId = tabs[prevIndex].id
        debugPrepareWorkspaceSwitch("prev", from: currentId, to: prevId)
#endif
        activateWorkspaceCycleHotWindow()
        selectWorkspaceId(
            tabs[prevIndex].id,
            notificationDismissalContext: .explicitWorkspaceResume
        )
    }

    private func activateWorkspaceCycleHotWindow() {
        workspaceCycleGeneration &+= 1
        let generation = workspaceCycleGeneration
#if DEBUG
        let switchId = debugWorkspaceSwitchId
        let switchDtMs = debugWorkspaceSwitchStartTime > 0
            ? (CACurrentMediaTime() - debugWorkspaceSwitchStartTime) * 1000
            : 0
#endif
        if !isWorkspaceCycleHot {
            isWorkspaceCycleHot = true
#if DEBUG
            cmuxDebugLog(
                "ws.hot.on id=\(switchId) gen=\(generation) dt=\(Self.debugMsText(switchDtMs))"
            )
#endif
        }

        let hadPendingCooldown = workspaceCycleCooldownTask != nil
        workspaceCycleCooldownTask?.cancel()
#if DEBUG
        if hadPendingCooldown {
            cmuxDebugLog(
                "ws.hot.cancelPrev id=\(switchId) gen=\(generation) dt=\(Self.debugMsText(switchDtMs))"
            )
        }
#endif
        workspaceCycleCooldownTask = Task { [weak self, generation] in
            do {
                try await Task.sleep(nanoseconds: 220_000_000)
            } catch {
#if DEBUG
                await MainActor.run {
                    guard let self else { return }
                    let dtMs = self.debugWorkspaceSwitchStartTime > 0
                        ? (CACurrentMediaTime() - self.debugWorkspaceSwitchStartTime) * 1000
                        : 0
                    cmuxDebugLog(
                        "ws.hot.cooldownCanceled id=\(self.debugWorkspaceSwitchId) gen=\(generation) dt=\(Self.debugMsText(dtMs))"
                    )
                }
#endif
                return
            }
            await MainActor.run {
                guard let self else { return }
                guard self.workspaceCycleGeneration == generation else { return }
#if DEBUG
                let dtMs = self.debugWorkspaceSwitchStartTime > 0
                    ? (CACurrentMediaTime() - self.debugWorkspaceSwitchStartTime) * 1000
                    : 0
                cmuxDebugLog(
                    "ws.hot.off id=\(self.debugWorkspaceSwitchId) gen=\(generation) dt=\(Self.debugMsText(dtMs))"
                )
#endif
                self.isWorkspaceCycleHot = false
                self.workspaceCycleCooldownTask = nil
            }
        }
    }

#if DEBUG
    func debugCurrentWorkspaceSwitchSnapshot() -> (id: UInt64, startedAt: CFTimeInterval)? {
        guard debugWorkspaceSwitchId > 0, debugWorkspaceSwitchStartTime > 0 else { return nil }
        return (debugWorkspaceSwitchId, debugWorkspaceSwitchStartTime)
    }

    func debugPrimeWorkspaceSwitchTrigger(_ trigger: String, to target: UUID?) {
        guard selectedTabId != target else {
            debugPendingWorkspaceSwitchTrigger = nil
            debugPendingWorkspaceSwitchTarget = nil
            return
        }
        debugPendingWorkspaceSwitchTrigger = trigger
        debugPendingWorkspaceSwitchTarget = target
    }

    private func debugPrepareWorkspaceSwitch(_ trigger: String, from: UUID?, to: UUID?) {
        guard from != to else {
            debugPendingWorkspaceSwitchTrigger = nil
            debugPendingWorkspaceSwitchTarget = nil
            debugPreparedWorkspaceSwitchTarget = nil
            return
        }
        debugPendingWorkspaceSwitchTrigger = nil
        debugPendingWorkspaceSwitchTarget = nil
        debugBeginWorkspaceSwitch(trigger: trigger, from: from, to: to)
        debugPreparedWorkspaceSwitchTarget = to
    }

    private func debugBeginWorkspaceSwitch(trigger: String, from: UUID?, to: UUID?) {
        debugWorkspaceSwitchCounter &+= 1
        debugWorkspaceSwitchId = debugWorkspaceSwitchCounter
        debugWorkspaceSwitchStartTime = CACurrentMediaTime()
        cmuxDebugLog(
            "ws.switch.begin id=\(debugWorkspaceSwitchId) trigger=\(trigger) " +
            "from=\(Self.debugShortWorkspaceId(from)) to=\(Self.debugShortWorkspaceId(to)) " +
            "hot=\(isWorkspaceCycleHot ? 1 : 0) tabs=\(tabs.count)"
        )
    }

    private static func debugShortWorkspaceId(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        return String(id.uuidString.prefix(5))
    }

    private static func debugTitlePreview(_ title: String, limit: Int = 120) -> String {
        let escaped = title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\"", with: "\\\"")
        guard escaped.count > limit else { return escaped }
        return "\(escaped.prefix(limit))..."
    }

    private static func debugMsText(_ ms: Double) -> String {
        String(format: "%.2fms", ms)
    }
#endif

    func selectTab(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }
#if DEBUG
        debugPrimeWorkspaceSwitchTrigger("select_index", to: tabs[index].id)
#endif
        selectWorkspaceId(tabs[index].id, notificationDismissalContext: .explicitWorkspaceResume)
    }

    func selectLastTab() {
        guard let lastTab = tabs.last else { return }
        selectWorkspaceId(lastTab.id, notificationDismissalContext: .explicitWorkspaceResume)
    }

    // MARK: - Surface Navigation

    /// Select the next surface in the currently focused pane of the selected workspace
    func selectNextSurface() {
        selectedWorkspace?.selectNextSurface()
    }

    /// Select the previous surface in the currently focused pane of the selected workspace
    func selectPreviousSurface() {
        selectedWorkspace?.selectPreviousSurface()
    }

    /// Select a surface by index in the currently focused pane of the selected workspace
    func selectSurface(at index: Int) {
        selectedWorkspace?.selectSurface(at: index)
    }

    /// Select the last surface in the currently focused pane of the selected workspace
    func selectLastSurface() {
        selectedWorkspace?.selectLastSurface()
    }

    /// Create a new terminal surface in the focused pane of the selected workspace
    func newSurface() {
        // Cmd+T should always focus the newly created surface.
        selectedWorkspace?.clearSplitZoom()
        selectedWorkspace?.newTerminalSurfaceInFocusedPane(focus: true)
    }

    func newSurface(initialInput: String) {
        selectedWorkspace?.clearSplitZoom()
        selectedWorkspace?.newTerminalSurfaceInFocusedPane(focus: true, initialInput: initialInput)
    }

    // MARK: - Split Creation

    /// Create a new split in the current tab
    @discardableResult
    func createSplit(direction: SplitDirection) -> UUID? {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }),
              let focusedPanelId = tab.focusedPanelId else { return nil }
        return createSplit(tabId: selectedTabId, surfaceId: focusedPanelId, direction: direction)
    }

    /// Create a new split from an explicit source panel.
    @discardableResult
    func createSplit(tabId: UUID, surfaceId: UUID, direction: SplitDirection, focus: Bool = true) -> UUID? {
        guard let tab = tabs.first(where: { $0.id == tabId }),
              tab.panels[surfaceId] != nil else { return nil }
        tab.clearSplitZoom()
        sentryBreadcrumb("split.create", data: ["direction": String(describing: direction)])
        return newSplit(tabId: tabId, surfaceId: surfaceId, direction: direction, focus: focus)
    }

    /// Create a new browser split from the currently focused panel.
    @discardableResult
    func createBrowserSplit(direction: SplitDirection, url: URL? = nil) -> UUID? {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }),
              let focusedPanelId = tab.focusedPanelId else { return nil }
        tab.clearSplitZoom()
        return newBrowserSplit(
            tabId: selectedTabId,
            fromPanelId: focusedPanelId,
            orientation: direction.orientation,
            insertFirst: direction.insertFirst,
            url: url
        )
    }

    /// Refresh Bonsplit right-side action button tooltips for all workspaces.
    func refreshSplitButtonTooltips() {
        for workspace in tabs {
            workspace.refreshSplitButtonTooltips()
        }
    }

    func refreshTabCloseButtonVisibility() {
        for workspace in tabs {
            workspace.refreshTabCloseButtonVisibility()
        }
    }

    func applySurfaceTabBarButtons(
        _ buttons: [CmuxSurfaceTabBarButton],
        sourcePath: String?,
        globalConfigPath: String,
        terminalCommandSourcePaths: [String: String],
        workspaceCommands: [String: CmuxResolvedCommand]
    ) {
        for workspace in tabs {
            workspace.applySurfaceTabBarButtons(
                buttons,
                sourcePath: sourcePath,
                globalConfigPath: globalConfigPath,
                terminalCommandSourcePaths: terminalCommandSourcePaths,
                workspaceCommands: workspaceCommands
            )
        }
    }

    // MARK: - Pane Focus Navigation

    /// Move focus to an adjacent pane in the specified direction
    func movePaneFocus(direction: NavigationDirection) {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }) else { return }
        tab.moveFocus(direction: direction)
    }

    // MARK: - Focus History Navigation

    @discardableResult
    private func withFocusHistoryRecordingSuppressed<Result>(_ body: () throws -> Result) rethrows -> Result {
        focusHistoryRecordingSuppressionDepth += 1
        defer {
            focusHistoryRecordingSuppressionDepth = max(0, focusHistoryRecordingSuppressionDepth - 1)
        }
        return try body()
    }

    private func recordFocusInHistory(
        workspaceId: UUID,
        panelId: UUID?,
        preservingForwardBranch: Bool = false
    ) {
        guard shouldRecordFocusHistory else { return }
        let entry = FocusHistoryEntry(workspaceId: workspaceId, panelId: panelId)
        guard focusHistoryEntryIsValid(entry) else { return }

        if historyIndex >= 0,
           historyIndex < focusHistory.count,
           focusHistory[historyIndex].entry == entry {
            return
        }

        var didMutateHistory = false
        if historyIndex < focusHistory.count - 1 {
            if preservingForwardBranch {
                let insertionIndex = max(0, historyIndex + 1)
                if focusHistory[insertionIndex].entry == entry {
                    let oldHistoryIndex = historyIndex
                    historyIndex = insertionIndex
                    if historyIndex != oldHistoryIndex {
                        focusHistoryRevision &+= 1
                    }
                    return
                }

                focusHistory.insert(FocusHistoryRecord(entry: entry), at: insertionIndex)
                let overflow = max(0, focusHistory.count - maxHistorySize)
                if overflow > 0 {
                    focusHistory.removeFirst(overflow)
                }
                historyIndex = max(-1, insertionIndex - overflow)
                focusHistoryRevision &+= 1
                return
            } else {
                focusHistory = Array(focusHistory.prefix(historyIndex + 1))
                didMutateHistory = true
            }
        }

        if focusHistory.last?.entry == entry {
            historyIndex = focusHistory.count - 1
            if didMutateHistory {
                focusHistoryRevision &+= 1
            }
            return
        }

        focusHistory.append(FocusHistoryRecord(entry: entry))
        if focusHistory.count > maxHistorySize {
            focusHistory.removeFirst(focusHistory.count - maxHistorySize)
        }

        historyIndex = focusHistory.count - 1
        focusHistoryRevision &+= 1
    }

    private func recordFocusInHistory(
        _ entry: FocusHistoryEntry?,
        preservingForwardBranch: Bool = false
    ) {
        guard let entry else { return }
        recordFocusInHistory(
            workspaceId: entry.workspaceId,
            panelId: entry.panelId,
            preservingForwardBranch: preservingForwardBranch
        )
    }

    private func recordImplicitFocusInHistory(workspaceId: UUID, panelId: UUID?) {
        guard shouldRecordFocusHistory else { return }
        let entry = FocusHistoryEntry(workspaceId: workspaceId, panelId: panelId)
        guard focusHistoryEntryIsValid(entry) else { return }

        if historyIndex >= 0,
           historyIndex < focusHistory.count - 1,
           focusHistory[historyIndex].entry.workspaceId == workspaceId {
            if focusHistory[historyIndex].entry != entry {
                focusHistory[historyIndex] = FocusHistoryRecord(entry: entry)
                focusHistoryRevision &+= 1
            }
            return
        }

        recordFocusInHistory(workspaceId: workspaceId, panelId: panelId)
    }

    func invalidateFocusHistoryTarget(workspaceId: UUID, panelId: UUID?) {
        if let panelId {
            guard focusHistory.contains(where: { $0.entry.workspaceId == workspaceId && $0.entry.panelId == panelId }) else {
                return
            }
            focusHistoryRevision &+= 1
            return
        }

        let oldCount = focusHistory.count
        guard oldCount > 0 else { return }

        let currentIndex = historyIndex
        let removedBeforeOrAtCurrent = focusHistory
            .prefix(max(0, min(currentIndex + 1, oldCount)))
            .filter { $0.entry.workspaceId == workspaceId }
            .count
        focusHistory.removeAll { $0.entry.workspaceId == workspaceId }
        guard focusHistory.count != oldCount else { return }

        historyIndex -= removedBeforeOrAtCurrent
        if focusHistory.isEmpty {
            historyIndex = -1
        } else {
            historyIndex = min(max(-1, historyIndex), focusHistory.count - 1)
        }
        focusHistoryRevision &+= 1
    }

    private func panelIdForFocusHistorySurface(_ surfaceId: UUID, workspaceId: UUID) -> UUID {
        tabs.first(where: { $0.id == workspaceId })?.panelIdFromSurfaceId(TabID(uuid: surfaceId)) ?? surfaceId
    }

    private func focusHistoryEntryIsValid(_ entry: FocusHistoryEntry) -> Bool {
        guard let workspace = tabs.first(where: { $0.id == entry.workspaceId }) else { return false }
        guard let panelId = entry.panelId else { return true }
        return workspace.panels[panelId] != nil
    }

    private func focusHistoryWorkspace(for entry: FocusHistoryEntry) -> Workspace? {
        tabs.first(where: { $0.id == entry.workspaceId })
    }

    private func resolvedFocusHistoryPanelId(for entry: FocusHistoryEntry, in workspace: Workspace) -> UUID? {
        if let panelId = entry.panelId, workspace.panels[panelId] != nil {
            return panelId
        }

        if let rememberedPanelId = focusedPanelId(for: workspace.id),
           workspace.panels[rememberedPanelId] != nil {
            return rememberedPanelId
        }

        if let workspacePanelId = workspace.focusedPanelId,
           workspace.panels[workspacePanelId] != nil {
            return workspacePanelId
        }

        return workspace.panels.keys.sorted { $0.uuidString < $1.uuidString }.first
    }

    private var currentFocusHistoryEntry: FocusHistoryEntry? {
        guard let selectedTabId else { return nil }
        return FocusHistoryEntry(workspaceId: selectedTabId, panelId: focusedPanelId(for: selectedTabId))
    }

    private func resolvedFocusHistoryEntry(for entry: FocusHistoryEntry) -> FocusHistoryEntry? {
        guard let workspace = focusHistoryWorkspace(for: entry) else { return nil }
        // Closed panels still leave a useful workspace-level history entry.
        // Resolve them to the workspace's current remembered panel instead of
        // discarding the user's ability to jump back to that workspace.
        return FocusHistoryEntry(
            workspaceId: workspace.id,
            panelId: resolvedFocusHistoryPanelId(for: entry, in: workspace)
        )
    }

    private func focusHistoryEntryResolvesToCurrent(_ entry: FocusHistoryEntry, currentEntry: FocusHistoryEntry?) -> Bool {
        guard let currentEntry,
              let resolvedEntry = resolvedFocusHistoryEntry(for: entry) else { return false }
        return resolvedEntry == currentEntry
    }

    private func focusHistoryEntryIsNavigable(_ entry: FocusHistoryEntry, currentEntry: FocusHistoryEntry?) -> Bool {
        guard resolvedFocusHistoryEntry(for: entry) != nil else { return false }
        if focusHistoryEntryResolvesToCurrent(entry, currentEntry: currentEntry) { return false }
        return true
    }

    func focusHistoryMenuSnapshot(
        direction: FocusHistoryMenuDirection,
        maxItemCount: Int? = nil
    ) -> FocusHistoryMenuSnapshot {
        let currentEntry = currentFocusHistoryEntry
        let historyIndices: [Int]
        switch direction {
        case .back:
            let lastBackIndex = min(historyIndex, focusHistory.count) - 1
            historyIndices = lastBackIndex >= 0
                ? Array(stride(from: lastBackIndex, through: 0, by: -1))
                : []
        case .forward:
            historyIndices = historyIndex < focusHistory.count - 1
                ? Array((historyIndex + 1)..<focusHistory.count)
                : []
        }

        let items = historyIndices.compactMap { index -> FocusHistoryMenuItem? in
            let record = focusHistory[index]
            let entry = record.entry
            guard let resolvedEntry = resolvedFocusHistoryEntry(for: entry),
                  let workspace = focusHistoryWorkspace(for: resolvedEntry),
                  focusHistoryEntryIsNavigable(entry, currentEntry: currentEntry) else {
                return nil
            }

            let workspaceTitle = workspace.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let panelTitle = resolvedEntry.panelId
                .flatMap { workspace.panelTitle(panelId: $0) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let position: FocusHistoryMenuPosition = direction == .back ? .older : .newer

            return FocusHistoryMenuItem(
                historyIndex: index,
                entry: entry,
                workspaceTitle: workspaceTitle,
                panelTitle: panelTitle?.isEmpty == true ? nil : panelTitle,
                position: position,
                focusedAt: record.focusedAt,
                isNavigable: true
            )
        }
        if let maxItemCount, maxItemCount >= 0, items.count > maxItemCount {
            return FocusHistoryMenuSnapshot(
                items: Array(items.prefix(maxItemCount)),
                totalItemCount: items.count,
                isLimited: true
            )
        }

        return FocusHistoryMenuSnapshot(
            items: items,
            totalItemCount: items.count,
            isLimited: false
        )
    }

    @discardableResult
    private func restoreFocusHistoryEntry(_ entry: FocusHistoryEntry) -> Bool {
        guard let workspace = tabs.first(where: { $0.id == entry.workspaceId }) else { return false }

        if selectedTabId != workspace.id {
            selectedTabId = workspace.id
        }

        let targetPanelId = resolvedFocusHistoryPanelId(for: entry, in: workspace)

        if let targetPanelId {
            rememberFocusedSurface(tabId: workspace.id, surfaceId: targetPanelId)
            workspace.focusPanel(targetPanelId)
            workspace.triggerFocusFlash(panelId: targetPanelId)
        } else {
            focusSelectedTabPanel(previousTabId: nil)
        }

        return true
    }

    @discardableResult
    private func navigateToFocusHistoryEntry(_ entry: FocusHistoryEntry, targetIndex: Int) -> Bool {
        var didNavigate = false
        defer {
            if didNavigate {
                focusHistoryRevision &+= 1
            }
        }

        var didRestore = false
        withFocusHistoryRecordingSuppressed {
            didRestore = restoreFocusHistoryEntry(entry)
        }
        guard didRestore else { return false }
        historyIndex = targetIndex
        didNavigate = true
        return true
    }

    @discardableResult
    func navigateToFocusHistoryMenuItem(_ item: FocusHistoryMenuItem) -> Bool {
        guard focusHistoryEntryIsNavigable(item.entry, currentEntry: currentFocusHistoryEntry) else { return false }
        var targetIndex = item.historyIndex
        guard focusHistory.indices.contains(targetIndex), focusHistory[targetIndex].entry == item.entry else {
            guard let fallbackIndex = focusHistory.lastIndex(where: { $0.entry == item.entry }) else { return false }
            targetIndex = fallbackIndex
            return navigateToFocusHistoryEntry(item.entry, targetIndex: targetIndex)
        }
        return navigateToFocusHistoryEntry(focusHistory[targetIndex].entry, targetIndex: targetIndex)
    }

    @discardableResult
    func navigateBack() -> Bool {
        guard historyIndex > 0 else { return false }

        let currentEntry = currentFocusHistoryEntry
        var targetIndex = historyIndex - 1
        while targetIndex >= 0 {
            let entry = focusHistory[targetIndex].entry
            guard focusHistoryWorkspace(for: entry) != nil else {
                focusHistory.remove(at: targetIndex)
                historyIndex -= 1
                targetIndex -= 1
                focusHistoryRevision &+= 1
                continue
            }
            if focusHistoryEntryResolvesToCurrent(entry, currentEntry: currentEntry) {
                targetIndex -= 1
                continue
            }
            if navigateToFocusHistoryEntry(entry, targetIndex: targetIndex) {
                return true
            }
            focusHistory.remove(at: targetIndex)
            historyIndex -= 1
            targetIndex -= 1
            focusHistoryRevision &+= 1
        }
        return false
    }

    @discardableResult
    func navigateForward() -> Bool {
        guard historyIndex < focusHistory.count - 1 else { return false }

        let currentEntry = currentFocusHistoryEntry
        var targetIndex = historyIndex + 1
        while targetIndex < focusHistory.count {
            let entry = focusHistory[targetIndex].entry
            guard focusHistoryWorkspace(for: entry) != nil else {
                focusHistory.remove(at: targetIndex)
                focusHistoryRevision &+= 1
                continue
            }
            if focusHistoryEntryResolvesToCurrent(entry, currentEntry: currentEntry) {
                targetIndex += 1
                continue
            }
            if navigateToFocusHistoryEntry(entry, targetIndex: targetIndex) {
                return true
            }
            focusHistory.remove(at: targetIndex)
            focusHistoryRevision &+= 1
        }
        return false
    }

    var canNavigateBack: Bool {
        let currentEntry = currentFocusHistoryEntry
        return historyIndex > 0 && focusHistory.prefix(historyIndex).contains { record in
            focusHistoryEntryIsNavigable(record.entry, currentEntry: currentEntry)
        }
    }

    var canNavigateForward: Bool {
        let currentEntry = currentFocusHistoryEntry
        return historyIndex < focusHistory.count - 1 && focusHistory.suffix(from: historyIndex + 1).contains { record in
            focusHistoryEntryIsNavigable(record.entry, currentEntry: currentEntry)
        }
    }

    // MARK: - Split Operations (Backwards Compatibility)

    /// Create a new split in the specified direction
    /// Returns the new panel's ID (which is also the surface ID for terminals)
    func newSplit(
        tabId: UUID,
        surfaceId: UUID,
        direction: SplitDirection,
        focus: Bool = true,
        workingDirectory: String? = nil,
        initialCommand: String? = nil,
        tmuxStartCommand: String? = nil,
        startupEnvironment: [String: String] = [:],
        initialDividerPosition: CGFloat? = nil,
        remotePTYSessionID: String? = nil
    ) -> UUID? {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return nil }
        return tab.newTerminalSplit(
            from: surfaceId,
            orientation: direction.orientation,
            insertFirst: direction.insertFirst,
            focus: focus,
            workingDirectory: workingDirectory,
            initialCommand: initialCommand,
            tmuxStartCommand: tmuxStartCommand,
            startupEnvironment: startupEnvironment,
            initialDividerPosition: initialDividerPosition,
            remotePTYSessionID: remotePTYSessionID
        )?.id
    }

    /// Move focus in the specified direction
    func moveSplitFocus(tabId: UUID, surfaceId: UUID, direction: NavigationDirection) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return false }
        tab.moveFocus(direction: direction)
        return true
    }

    /// Resize split - not directly supported by bonsplit, but we can adjust divider positions
    func resizeSplit(tabId: UUID, surfaceId: UUID, direction: ResizeDirection, amount: UInt16) -> Bool {
        guard amount > 0,
              let tab = tabs.first(where: { $0.id == tabId }),
              let paneId = tab.paneId(forPanelId: surfaceId) else { return false }

        let paneUUID = paneId.id
        guard tab.bonsplitController.allPaneIds.contains(where: { $0.id == paneUUID }) else {
            return false
        }

        var candidates: [ResizeSplitCandidate] = []
        let trace = resizeSplitCollectCandidates(
            node: tab.bonsplitController.treeSnapshot(),
            targetPaneId: paneUUID.uuidString,
            candidates: &candidates
        )
        guard trace.containsTarget else { return false }

        let orientationMatches = candidates.filter { $0.orientation == direction.splitOrientation }
        guard !orientationMatches.isEmpty else { return false }

        guard let candidate = orientationMatches.first(where: {
            $0.paneInFirstChild == direction.requiresPaneInFirstChild
        }) else {
            return false
        }

        let delta = CGFloat(amount) / candidate.axisPixels
        let requested = candidate.dividerPosition + (direction.dividerDeltaSign * delta)
        let clamped = min(max(requested, 0.1), 0.9)
        return tab.bonsplitController.setDividerPosition(clamped, forSplit: candidate.splitId, fromExternal: true)
    }

    /// Toggle zoom on a panel.
    func toggleSplitZoom(tabId: UUID, surfaceId: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return false }
        return tab.toggleSplitZoom(panelId: surfaceId)
    }

    /// Toggle zoom for the currently focused panel in the selected workspace.
    @discardableResult
    func toggleFocusedSplitZoom() -> Bool {
        guard let tab = selectedWorkspace,
              let focusedPanelId = tab.focusedPanelId else { return false }
        return tab.toggleSplitZoom(panelId: focusedPanelId)
    }

    private struct ResizeSplitCandidate {
        let splitId: UUID
        let orientation: String
        let paneInFirstChild: Bool
        let dividerPosition: CGFloat
        let axisPixels: CGFloat
    }

    private struct ResizeSplitTrace {
        let containsTarget: Bool
        let bounds: CGRect
    }

    private func resizeSplitCollectCandidates(
        node: ExternalTreeNode,
        targetPaneId: String,
        candidates: inout [ResizeSplitCandidate]
    ) -> ResizeSplitTrace {
        switch node {
        case .pane(let pane):
            let bounds = CGRect(
                x: pane.frame.x,
                y: pane.frame.y,
                width: pane.frame.width,
                height: pane.frame.height
            )
            return ResizeSplitTrace(containsTarget: pane.id == targetPaneId, bounds: bounds)

        case .split(let split):
            let first = resizeSplitCollectCandidates(
                node: split.first,
                targetPaneId: targetPaneId,
                candidates: &candidates
            )
            let second = resizeSplitCollectCandidates(
                node: split.second,
                targetPaneId: targetPaneId,
                candidates: &candidates
            )

            let combinedBounds = first.bounds.union(second.bounds)
            let containsTarget = first.containsTarget || second.containsTarget

            if containsTarget,
               let splitUUID = UUID(uuidString: split.id) {
                let orientation = split.orientation.lowercased()
                let axisPixels: CGFloat = orientation == "horizontal"
                    ? combinedBounds.width
                    : combinedBounds.height
                candidates.append(ResizeSplitCandidate(
                    splitId: splitUUID,
                    orientation: orientation,
                    paneInFirstChild: first.containsTarget,
                    dividerPosition: CGFloat(split.dividerPosition),
                    axisPixels: max(axisPixels, 1)
                ))
            }

            return ResizeSplitTrace(containsTarget: containsTarget, bounds: combinedBounds)
        }
    }

    /// Close a surface/panel
    func closeSurface(tabId: UUID, surfaceId: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return false }
        // Guard against stale close callbacks (e.g. child-exit can trigger multiple actions).
        // A stale callback must never affect unrelated panels/workspaces.
        guard tab.panels[surfaceId] != nil,
              tab.surfaceIdFromPanelId(surfaceId) != nil else { return false }
        tab.closePanel(surfaceId)
        AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: tabId, surfaceId: surfaceId)
        return true
    }

    /// Create a new browser panel in a split
    func newBrowserSplit(
        tabId: UUID,
        fromPanelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool = false,
        url: URL? = nil,
        preferredProfileID: UUID? = nil,
        focus: Bool = true,
        initialDividerPosition: CGFloat? = nil
    ) -> UUID? {
        guard BrowserAvailabilitySettings.isEnabled() else { return nil }
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return nil }
        return tab.newBrowserSplit(
            from: fromPanelId,
            orientation: orientation,
            insertFirst: insertFirst,
            url: url,
            preferredProfileID: preferredProfileID,
            focus: focus,
            initialDividerPosition: initialDividerPosition
        )?.id
    }

    /// Create a new browser surface in a pane
    func newBrowserSurface(
        tabId: UUID,
        inPane paneId: PaneID,
        url: URL? = nil,
        preferredProfileID: UUID? = nil
    ) -> UUID? {
        guard BrowserAvailabilitySettings.isEnabled() else { return nil }
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return nil }
        return tab.newBrowserSurface(
            inPane: paneId,
            url: url,
            preferredProfileID: preferredProfileID
        )?.id
    }

    /// Get a browser panel by ID
    func browserPanel(tabId: UUID, panelId: UUID) -> BrowserPanel? {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return nil }
        return tab.browserPanel(for: panelId)
    }

    /// Open a browser in a specific workspace, optionally preferring a split-right layout.
    @discardableResult
    func openBrowser(
        inWorkspace tabId: UUID,
        url: URL? = nil,
        preferSplitRight: Bool = false,
        preferredProfileID: UUID? = nil,
        insertAtEnd: Bool = false
    ) -> UUID? {
        guard BrowserAvailabilitySettings.isEnabled() else { return nil }
        guard let workspace = tabs.first(where: { $0.id == tabId }) else { return nil }
        if selectedTabId != tabId {
            selectWorkspaceId(tabId, notificationDismissalContext: .explicitWorkspaceResume)
        }

        if preferSplitRight {
            if let targetPaneId = workspace.topRightBrowserReusePane(),
               let browserPanel = workspace.newBrowserSurface(
                   inPane: targetPaneId,
                   url: url,
                   focus: true,
                   insertAtEnd: insertAtEnd,
                   preferredProfileID: preferredProfileID
               ) {
                rememberFocusedSurface(tabId: tabId, surfaceId: browserPanel.id)
                return browserPanel.id
            }

            let splitSourcePanelId: UUID? = {
                if let focusedPanelId = workspace.focusedPanelId,
                   workspace.panels[focusedPanelId] != nil {
                    return focusedPanelId
                }
                if let rememberedPanelId = lastFocusedPanelByTab[tabId],
                   workspace.panels[rememberedPanelId] != nil {
                    return rememberedPanelId
                }
                if let orderedPanelId = workspace.sidebarOrderedPanelIds().first(where: { workspace.panels[$0] != nil }) {
                    return orderedPanelId
                }
                return workspace.panels.keys.sorted { $0.uuidString < $1.uuidString }.first
            }()

            if let splitSourcePanelId,
               let browserPanel = workspace.newBrowserSplit(
                   from: splitSourcePanelId,
                   orientation: .horizontal,
                   url: url,
                   preferredProfileID: preferredProfileID,
                   focus: true
               ) {
                rememberFocusedSurface(tabId: tabId, surfaceId: browserPanel.id)
                return browserPanel.id
            }
        }

        guard let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first,
              let browserPanel = workspace.newBrowserSurface(
                  inPane: paneId,
                  url: url,
                  focus: true,
                  insertAtEnd: insertAtEnd,
                  preferredProfileID: preferredProfileID
              ) else {
            return nil
        }
        rememberFocusedSurface(tabId: tabId, surfaceId: browserPanel.id)
        return browserPanel.id
    }

    /// Open a browser in the currently focused pane (as a new surface)
    @discardableResult
    func openBrowser(
        url: URL? = nil,
        preferredProfileID: UUID? = nil,
        insertAtEnd: Bool = false
    ) -> UUID? {
        guard let tabId = selectedTabId else { return nil }
        return openBrowser(
            inWorkspace: tabId,
            url: url,
            preferSplitRight: false,
            preferredProfileID: preferredProfileID,
            insertAtEnd: insertAtEnd
        )
    }

    /// Reopen the most recently closed browser panel (Cmd+Shift+T).
    /// No-op when no browser panel restore snapshot is available.
    @discardableResult
    func reopenMostRecentlyClosedBrowserPanel() -> Bool {
        if reopenMostRecentlyClosedItem() {
            return true
        }

        return reopenMostRecentlyClosedBrowserPanelFromLegacyStack()
    }

    @discardableResult
    func reopenMostRecentlyClosedBrowserPanelFromLegacyStack() -> Bool {
        guard BrowserAvailabilitySettings.isEnabled() else { return false }

        while let snapshot = recentlyClosedBrowsers.pop() {
            guard let targetWorkspace =
                tabs.first(where: { $0.id == snapshot.workspaceId })
                ?? selectedWorkspace
                ?? tabs.first else {
                return false
            }
            let preReopenFocusedPanelId = focusedPanelId(for: targetWorkspace.id)

            if selectedTabId != targetWorkspace.id {
                selectWorkspaceId(
                    targetWorkspace.id,
                    notificationDismissalContext: .explicitWorkspaceResume
                )
            }

            if let reopenedPanelId = reopenClosedBrowserPanel(snapshot, in: targetWorkspace) {
                enforceReopenedBrowserFocus(
                    tabId: targetWorkspace.id,
                    reopenedPanelId: reopenedPanelId,
                    preReopenFocusedPanelId: preReopenFocusedPanelId
                )
                return true
            }
        }

        return false
    }

    func clearRecentlyClosedBrowserPanelHistory() {
        recentlyClosedBrowsers = RecentlyClosedBrowserStack(capacity: 20)
    }

    func mostRecentLegacyClosedBrowserPanelClosedAt() -> Date? {
        recentlyClosedBrowsers.mostRecentClosedAt
    }

    @discardableResult
    func reopenMostRecentlyClosedItem() -> Bool {
        if let appDelegate = AppDelegate.shared {
            return appDelegate.reopenMostRecentlyClosedItem(preferredTabManager: self)
        }

        if ClosedItemHistoryStore.shared.restoreFirstRestorable(using: { entry in
            switch entry {
            case .panel(let panelEntry):
                return restoreClosedPanel(panelEntry)
            case .workspace(let workspaceEntry):
                return restoreClosedWorkspace(workspaceEntry)
            case .window:
                return false
            }
        }) {
            return true
        }

        return false
    }

    @discardableResult
    func reopenClosedHistoryItem(id: UUID) -> Bool {
        if let appDelegate = AppDelegate.shared {
            return appDelegate.reopenClosedHistoryItem(id: id, preferredTabManager: self)
        }

        guard let removed = ClosedItemHistoryStore.shared.removeRecord(id: id) else {
            return false
        }

        let didRestore: Bool
        switch removed.record.entry {
        case .panel(let panelEntry):
            didRestore = restoreClosedPanel(panelEntry)
        case .workspace(let workspaceEntry):
            didRestore = restoreClosedWorkspace(workspaceEntry)
        case .window:
            didRestore = false
        }

        if !didRestore {
            ClosedItemHistoryStore.shared.insert(removed.record, at: removed.index)
        }
        return didRestore
    }

    @discardableResult
    func restoreClosedPanel(_ entry: ClosedPanelHistoryEntry) -> Bool {
        guard let workspace = tabs.first(where: { $0.id == entry.workspaceId }) else {
            return false
        }

        let preRestoreFocus = currentFocusHistoryEntry
        let panelId = withFocusHistoryRecordingSuppressed {
            workspace.restoreClosedPanel(entry)
        }

        guard let panelId else { return false }
        ClosedItemHistoryStore.shared.remapPanelAnchorIds(from: entry.snapshot.id, to: panelId)
        withFocusHistoryRecordingSuppressed {
            if selectedTabId != workspace.id {
                selectedTabId = workspace.id
            }
        }
        recordFocusInHistory(preRestoreFocus, preservingForwardBranch: true)
        rememberFocusedSurface(tabId: workspace.id, surfaceId: panelId)
        recordFocusInHistory(workspaceId: workspace.id, panelId: panelId, preservingForwardBranch: true)
        return true
    }

    @discardableResult
    func restoreClosedWorkspace(_ entry: ClosedWorkspaceHistoryEntry) -> Bool {
        let preRestoreFocus = currentFocusHistoryEntry
        let workspace = addWorkspace(
            title: entry.snapshot.customTitle ?? entry.snapshot.processTitle,
            workingDirectory: entry.snapshot.currentDirectory,
            select: false,
            autoWelcomeIfNeeded: false
        )
        let restoredPanelIds = workspace.restoreSessionSnapshot(entry.snapshot)
        guard !entry.snapshot.hasRestorablePanels || !restoredPanelIds.isEmpty else {
            closeWorkspace(workspace, recordHistory: false)
            return false
        }
        guard !workspace.panels.isEmpty else {
            closeWorkspace(workspace, recordHistory: false)
            return false
        }
        ClosedItemHistoryStore.shared.remapPanelWorkspaceIds(
            from: entry.workspaceId,
            to: workspace.id,
            panelIdMap: restoredPanelIds
        )

        if let currentIndex = tabs.firstIndex(where: { $0.id == workspace.id }) {
            let removed = tabs.remove(at: currentIndex)
            let insertIndex = min(max(entry.workspaceIndex, 0), tabs.count)
            tabs.insert(removed, at: insertIndex)
        }

        withFocusHistoryRecordingSuppressed {
            selectedTabId = workspace.id
        }
        recordFocusInHistory(preRestoreFocus, preservingForwardBranch: true)
        if let focusedPanelId = workspace.focusedPanelId {
            rememberFocusedSurface(tabId: workspace.id, surfaceId: focusedPanelId)
            workspace.triggerFocusFlash(panelId: focusedPanelId)
            recordFocusInHistory(workspaceId: workspace.id, panelId: focusedPanelId, preservingForwardBranch: true)
        } else {
            recordFocusInHistory(workspaceId: workspace.id, panelId: nil, preservingForwardBranch: true)
        }
        return true
    }

    private func enforceReopenedBrowserFocus(
        tabId: UUID,
        reopenedPanelId: UUID,
        preReopenFocusedPanelId: UUID?
    ) {
        // Keep workspace-switch restoration pinned to the reopened browser panel.
        rememberFocusedSurface(tabId: tabId, surfaceId: reopenedPanelId)
        enforceReopenedBrowserFocusIfNeeded(
            tabId: tabId,
            reopenedPanelId: reopenedPanelId,
            preReopenFocusedPanelId: preReopenFocusedPanelId
        )

        // Some stale focus callbacks can land one runloop turn later. Re-assert focus in two
        // consecutive turns, but only when focus drifted back to the pre-reopen panel.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.enforceReopenedBrowserFocusIfNeeded(
                tabId: tabId,
                reopenedPanelId: reopenedPanelId,
                preReopenFocusedPanelId: preReopenFocusedPanelId
            )
            DispatchQueue.main.async { [weak self] in
                self?.enforceReopenedBrowserFocusIfNeeded(
                    tabId: tabId,
                    reopenedPanelId: reopenedPanelId,
                    preReopenFocusedPanelId: preReopenFocusedPanelId
                )
            }
        }
    }

    private func enforceReopenedBrowserFocusIfNeeded(
        tabId: UUID,
        reopenedPanelId: UUID,
        preReopenFocusedPanelId: UUID?
    ) {
        guard selectedTabId == tabId,
              let tab = tabs.first(where: { $0.id == tabId }),
              tab.panels[reopenedPanelId] != nil else {
            return
        }

        rememberFocusedSurface(tabId: tabId, surfaceId: reopenedPanelId)

        guard tab.focusedPanelId != reopenedPanelId else { return }

        if let focusedPanelId = tab.focusedPanelId,
           let preReopenFocusedPanelId,
           focusedPanelId != preReopenFocusedPanelId {
            return
        }

        tab.focusPanel(reopenedPanelId)
    }

    private func reopenClosedBrowserPanel(
        _ snapshot: ClosedBrowserPanelRestoreSnapshot,
        in workspace: Workspace
    ) -> UUID? {
        if let originalPane = workspace.bonsplitController.allPaneIds.first(where: { $0.id == snapshot.originalPaneId }),
           let browserPanel = workspace.newBrowserSurface(
               inPane: originalPane,
               url: snapshot.url,
               focus: true,
               preferredProfileID: snapshot.profileID
           ) {
            let tabCount = workspace.bonsplitController.tabs(inPane: originalPane).count
            let maxIndex = max(0, tabCount - 1)
            let targetIndex = min(max(snapshot.originalTabIndex, 0), maxIndex)
            _ = workspace.reorderSurface(panelId: browserPanel.id, toIndex: targetIndex)
            return browserPanel.id
        }

        if let orientation = snapshot.fallbackSplitOrientation,
           let fallbackAnchorPaneId = snapshot.fallbackAnchorPaneId,
           let anchorPane = workspace.bonsplitController.allPaneIds.first(where: { $0.id == fallbackAnchorPaneId }),
           let anchorTab = workspace.bonsplitController.selectedTab(inPane: anchorPane) ?? workspace.bonsplitController.tabs(inPane: anchorPane).first,
           let anchorPanelId = workspace.panelIdFromSurfaceId(anchorTab.id),
           let browserPanelId = workspace.newBrowserSplit(
               from: anchorPanelId,
               orientation: orientation,
               insertFirst: snapshot.fallbackSplitInsertFirst,
               url: snapshot.url,
               preferredProfileID: snapshot.profileID
           )?.id {
            return browserPanelId
        }

        guard let focusedPane = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
            return nil
        }
        return workspace.newBrowserSurface(
            inPane: focusedPane,
            url: snapshot.url,
            focus: true,
            preferredProfileID: snapshot.profileID
        )?.id
    }

    /// Flash the currently focused panel so the user can visually confirm focus.
    func triggerFocusFlash() {
        guard let tab = selectedWorkspace,
              let panelId = tab.focusedPanelId else { return }
        tab.triggerFocusFlash(panelId: panelId)
    }

    /// Ensure AppKit first responder matches the currently focused terminal panel.
    /// This keeps real keyboard events (including Ctrl+D) on the same panel as the
    /// bonsplit focus indicator after rapid split topology changes.
    func ensureFocusedTerminalFirstResponder() {
        guard let tab = selectedWorkspace,
              let panelId = tab.focusedPanelId,
              let terminal = tab.terminalPanel(for: panelId) else { return }
        terminal.hostedView.ensureFocus(for: tab.id, surfaceId: panelId)
    }

    /// Reconcile keyboard routing before terminal control shortcuts (e.g. Ctrl+D).
    ///
    /// Source of truth for pane focus is bonsplit's focused pane + selected tab.
    /// Keyboard delivery must converge AppKit first responder to that model state, not mutate
    /// the model from whatever first responder happened to be during reparenting transitions.
    func reconcileFocusedPanelFromFirstResponderForKeyboard() {
        ensureFocusedTerminalFirstResponder()
    }

    /// Get a terminal panel by ID
    func terminalPanel(tabId: UUID, panelId: UUID) -> TerminalPanel? {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return nil }
        return tab.terminalPanel(for: panelId)
    }

    /// Get the panel for a surface ID (terminal panels use surface ID as panel ID)
    func surface(for tabId: UUID, surfaceId: UUID) -> TerminalSurface? {
        terminalPanel(tabId: tabId, panelId: surfaceId)?.surface
    }

#if DEBUG
    @MainActor
    private func waitForWorkspacePanelsCondition(
        tab: Workspace,
        timeoutSeconds: TimeInterval,
        condition: @escaping (Workspace) -> Bool
    ) async -> Bool {
        guard !condition(tab) else { return true }

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            var resolved = false
            var cancellable: AnyCancellable?

            func finish(_ value: Bool) {
                guard !resolved else { return }
                resolved = true
                cancellable?.cancel()
                cont.resume(returning: value)
            }

            func evaluate() {
                if condition(tab) {
                    finish(true)
                }
            }

            cancellable = tab.$panels
                .map { _ in () }
                .sink { _ in evaluate() }

            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) {
                Task { @MainActor in
                    finish(condition(tab))
                }
            }
            evaluate()
        }
    }

    @MainActor
    private func waitForTerminalPanelCondition(
        tab: Workspace,
        panelId: UUID,
        timeoutSeconds: TimeInterval,
        condition: @escaping (TerminalPanel) -> Bool
    ) async -> Bool {
        if let panel = tab.terminalPanel(for: panelId), condition(panel) {
            return true
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            var resolved = false
            var panelsCancellable: AnyCancellable?
            var readyObserver: NSObjectProtocol?
            var hostedViewObserver: NSObjectProtocol?

            @MainActor
            func finish(_ value: Bool) {
                guard !resolved else { return }
                resolved = true
                panelsCancellable?.cancel()
                if let readyObserver {
                    NotificationCenter.default.removeObserver(readyObserver)
                }
                if let hostedViewObserver {
                    NotificationCenter.default.removeObserver(hostedViewObserver)
                }
                cont.resume(returning: value)
            }

            @MainActor
            func evaluate() {
                guard let panel = tab.terminalPanel(for: panelId) else {
                    finish(false)
                    return
                }
                panel.surface.requestBackgroundSurfaceStartIfNeeded()
                if condition(panel) {
                    finish(true)
                }
            }

            panelsCancellable = tab.$panels
                .map { _ in () }
                .sink { _ in
                    Task { @MainActor in
                        evaluate()
                    }
                }
            readyObserver = NotificationCenter.default.addObserver(
                forName: .terminalSurfaceDidBecomeReady,
                object: nil,
                queue: .main
            ) { note in
                guard let readySurfaceId = note.userInfo?["surfaceId"] as? UUID,
                      readySurfaceId == panelId else { return }
                Task { @MainActor in
                    evaluate()
                }
            }
            hostedViewObserver = NotificationCenter.default.addObserver(
                forName: .terminalSurfaceHostedViewDidMoveToWindow,
                object: nil,
                queue: .main
            ) { note in
                guard let hostedSurfaceId = note.userInfo?["surfaceId"] as? UUID,
                      hostedSurfaceId == panelId else { return }
                Task { @MainActor in
                    evaluate()
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) {
                Task { @MainActor in
                    if let panel = tab.terminalPanel(for: panelId) {
                        finish(condition(panel))
                    } else {
                        finish(false)
                    }
                }
            }
            evaluate()
        }
    }

    @MainActor
    private func waitForTerminalPanelReadyForUITest(
        tab: Workspace,
        panelId: UUID,
        timeoutSeconds: TimeInterval = 6.0
    ) async -> (attached: Bool, hasSurface: Bool, firstResponder: Bool) {
        var attached = false
        var hasSurface = false
        var firstResponder = false

        let _ = await waitForTerminalPanelCondition(
            tab: tab,
            panelId: panelId,
            timeoutSeconds: timeoutSeconds
        ) { panel in
            panel.surface.requestBackgroundSurfaceStartIfNeeded()
            attached = panel.surface.isViewInWindow
            hasSurface = panel.surface.surface != nil
            firstResponder = panel.hostedView.isSurfaceViewFirstResponder()
            return attached && hasSurface
        }

        return (attached, hasSurface, firstResponder)
    }

    private func setupUITestFocusShortcutsIfNeeded() {
        guard !didSetupUITestFocusShortcuts else { return }
        didSetupUITestFocusShortcuts = true

        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_FOCUS_SHORTCUTS"] == "1" else { return }

        // UI tests can't record arrow keys via the shortcut recorder. Use letter-based shortcuts
        // so tests can reliably drive pane navigation without mouse clicks.
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

    private func setupSplitCloseRightUITestIfNeeded() {
        guard !didSetupSplitCloseRightUITest else { return }
        didSetupSplitCloseRightUITest = true

        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_SETUP"] == "1" else { return }
        guard let path = env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_PATH"], !path.isEmpty else { return }
        let visualMode = env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_VISUAL"] == "1"
        let shotsDir = (env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_SHOTS_DIR"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let visualIterations = Int((env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_ITERATIONS"] ?? "20").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 20
        let burstFrames = Int((env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_BURST_FRAMES"] ?? "6").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 6
        let closeDelayMs = Int((env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_CLOSE_DELAY_MS"] ?? "70").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 70
        let pattern = (env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_PATTERN"] ?? "close_right")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let tab = self.selectedWorkspace else {
                    self.writeSplitCloseRightTestData(["setupError": "Missing selected workspace"], at: path)
                    return
                }

                guard let topLeftPanelId = tab.focusedPanelId else {
                    self.writeSplitCloseRightTestData(["setupError": "Missing initial focused panel"], at: path)
                    return
                }
                let initialTerminalReadiness = await self.waitForTerminalPanelReadyForUITest(
                    tab: tab,
                    panelId: topLeftPanelId
                )

                guard initialTerminalReadiness.attached,
                      initialTerminalReadiness.hasSurface,
                      let terminal = tab.terminalPanel(for: topLeftPanelId) else {
                    self.writeSplitCloseRightTestData([
                        "preTerminalAttached": initialTerminalReadiness.attached ? "1" : "0",
                        "preTerminalSurfaceNil": initialTerminalReadiness.hasSurface ? "0" : "1",
                        "setupError": "Initial terminal not ready (not attached or surface nil)"
                    ], at: path)
                    return
                }

                self.writeSplitCloseRightTestData([
                    "preTerminalAttached": "1",
                    "preTerminalSurfaceNil": terminal.surface.surface == nil ? "1" : "0"
                ], at: path)

                if visualMode {
                    // Visual repro mode: repeat the split/close sequence many times and write
                    // screenshots to `shotsDir`. This avoids relying on XCUITest to click hover-only
                    // close buttons, while still exercising the "close unfocused right tabs" path.
                    self.writeSplitCloseRightTestData([
                        "visualMode": "1",
                        "visualIterations": String(visualIterations),
                        "visualDone": "0"
                    ], at: path)

                    await self.runSplitCloseRightVisualRepro(
                        tab: tab,
                        topLeftPanelId: topLeftPanelId,
                        path: path,
                        shotsDir: shotsDir,
                        iterations: max(1, min(visualIterations, 60)),
                        burstFrames: max(0, min(burstFrames, 80)),
                        closeDelayMs: max(0, min(closeDelayMs, 500)),
                        pattern: pattern
                    )

                    self.writeSplitCloseRightTestData(["visualDone": "1"], at: path)
                    return
                }

                // Layout goal: 2x2 grid (2 top, 2 bottom), then close both right panels.
                // Order matters: split down first, then split right in each row (matches UI shortcut repro).
                guard let bottomLeft = tab.newTerminalSplit(from: topLeftPanelId, orientation: .vertical) else {
                    self.writeSplitCloseRightTestData(["setupError": "Failed to create bottom-left split"], at: path)
                    return
                }
                guard let bottomRight = tab.newTerminalSplit(from: bottomLeft.id, orientation: .horizontal) else {
                    self.writeSplitCloseRightTestData(["setupError": "Failed to create bottom-right split"], at: path)
                    return
                }
                tab.focusPanel(topLeftPanelId)
                guard let topRight = tab.newTerminalSplit(from: topLeftPanelId, orientation: .horizontal) else {
                    self.writeSplitCloseRightTestData(["setupError": "Failed to create top-right split"], at: path)
                    return
                }

                self.writeSplitCloseRightTestData([
                    "tabId": tab.id.uuidString,
                    "topLeftPanelId": topLeftPanelId.uuidString,
                    "bottomLeftPanelId": bottomLeft.id.uuidString,
                    "topRightPanelId": topRight.id.uuidString,
                    "bottomRightPanelId": bottomRight.id.uuidString,
                    "createdPaneCount": String(tab.bonsplitController.allPaneIds.count),
                    "createdPanelCount": String(tab.panels.count)
                ], at: path)

                DebugUIEventCounters.resetEmptyPanelAppearCount()

                // Close the two right panes via the same path as the Close Tab shortcut.
                tab.focusPanel(topRight.id)
                tab.closePanel(topRight.id, force: true)
                tab.focusPanel(bottomRight.id)
                tab.closePanel(bottomRight.id, force: true)


                // Capture final state after Bonsplit/AppKit/Ghostty geometry reconciliation.
                // We avoid sleep-based timing and converge over a few main-actor turns.
                 @MainActor func collectSplitCloseRightState() -> (data: [String: String], settled: Bool) {
                    let paneIds = tab.bonsplitController.allPaneIds
                    let bonsplitTabCount = tab.bonsplitController.allTabIds.count
                    let panelCount = tab.panels.count

                    var missingSelectedTabCount = 0
                    var missingPanelMappingCount = 0
                    var selectedTerminalCount = 0
                    var selectedTerminalAttachedCount = 0
                    var selectedTerminalZeroSizeCount = 0
                    var selectedTerminalSurfaceNilCount = 0

                    for paneId in paneIds {
                        guard let selected = tab.bonsplitController.selectedTab(inPane: paneId) else {
                            missingSelectedTabCount += 1
                            continue
                        }
                        guard let panel = tab.panel(for: selected.id) else {
                            missingPanelMappingCount += 1
                            continue
                        }
                        if let terminal = panel as? TerminalPanel {
                            selectedTerminalCount += 1
                            if terminal.surface.isViewInWindow {
                                selectedTerminalAttachedCount += 1
                            }
                            let size = terminal.hostedView.bounds.size
                            if size.width < 5 || size.height < 5 {
                                selectedTerminalZeroSizeCount += 1
                            }
                            if terminal.surface.surface == nil {
                                selectedTerminalSurfaceNilCount += 1
                            }
                        }
                    }

                    let settled =
                        paneIds.count == 2 &&
                        missingSelectedTabCount == 0 &&
                        missingPanelMappingCount == 0 &&
                        DebugUIEventCounters.emptyPanelAppearCount == 0 &&
                        selectedTerminalCount == 2 &&
                        selectedTerminalAttachedCount == 2 &&
                        selectedTerminalZeroSizeCount == 0 &&
                        selectedTerminalSurfaceNilCount == 0

                    return (
                        data: [
                            "finalPaneCount": String(paneIds.count),
                            "finalBonsplitTabCount": String(bonsplitTabCount),
                            "finalPanelCount": String(panelCount),
                            "missingSelectedTabCount": String(missingSelectedTabCount),
                            "missingPanelMappingCount": String(missingPanelMappingCount),
                            "emptyPanelAppearCount": String(DebugUIEventCounters.emptyPanelAppearCount),
                            "selectedTerminalCount": String(selectedTerminalCount),
                            "selectedTerminalAttachedCount": String(selectedTerminalAttachedCount),
                            "selectedTerminalZeroSizeCount": String(selectedTerminalZeroSizeCount),
                            "selectedTerminalSurfaceNilCount": String(selectedTerminalSurfaceNilCount),
                        ],
                        settled: settled
                    )
                }
                 @MainActor func reconcileVisibleTerminalGeometry() {
                    NSApp.windows.forEach { window in
                        window.contentView?.layoutSubtreeIfNeeded()
                        window.contentView?.displayIfNeeded()
                    }
                    for paneId in tab.bonsplitController.allPaneIds {
                        guard let selected = tab.bonsplitController.selectedTab(inPane: paneId),
                              let terminal = tab.panel(for: selected.id) as? TerminalPanel else {
                            continue
                        }
                        terminal.hostedView.reconcileGeometryNow()
                        terminal.surface.forceRefresh()
                    }
                }

                var finalState = collectSplitCloseRightState()
                for attempt in 1...8 {
                    reconcileVisibleTerminalGeometry()
                    await Task.yield()
                    finalState = collectSplitCloseRightState()
                    var payload = finalState.data
                    payload["finalAttempt"] = String(attempt)
                    self.writeSplitCloseRightTestData(payload, at: path)
                    if finalState.settled {
                        break
                    }
                }
            }
        }
    }

	    @MainActor
	    private func runSplitCloseRightVisualRepro(
	        tab: Workspace,
	        topLeftPanelId: UUID,
	        path: String,
	        shotsDir: String,
	        iterations: Int,
	        burstFrames: Int,
	        closeDelayMs: Int,
	        pattern: String
	    ) async {
        _ = shotsDir // legacy: screenshots removed in favor of IOSurface sampling

        func sendText(_ panelId: UUID, _ text: String) {
            guard let tp = tab.terminalPanel(for: panelId) else { return }
            tp.sendText(text)
        }

        // Sample a very top strip so the probe remains valid even after vertical expand/collapse.
        // We pin marker text to row 1 before each close sequence.
        let sampleCrop = CGRect(x: 0.04, y: 0.01, width: 0.92, height: 0.08)

        for i in 1...iterations {
            // Reset to a single pane: close everything except the top-left panel.
            tab.focusPanel(topLeftPanelId)
            let toClose = Array(tab.panels.keys).filter { $0 != topLeftPanelId }
            for pid in toClose {
                tab.closePanel(pid, force: true)
            }

            // Create the repro layout. Most patterns use a 2x2 grid, but keep a single-split
            // variant for the exact "close right in a horizontal pair" user report.
            let topLeftId = topLeftPanelId
            let topRight: TerminalPanel
            var bottomLeft: TerminalPanel?
            var bottomRight: TerminalPanel?

            switch pattern {
            case "close_right_single":
                guard let tr = tab.newTerminalSplit(from: topLeftId, orientation: .horizontal) else {
                    writeSplitCloseRightTestData(["setupError": "Failed to split right from top-left (iteration \(i))"], at: path)
                    return
                }
                topRight = tr
            case "close_right_lrtd", "close_right_lrtd_bottom_first", "close_right_bottom_first", "close_right_lrtd_unfocused":
                // User repro: split left/right first, then split top/down in each column.
                guard let tr = tab.newTerminalSplit(from: topLeftId, orientation: .horizontal) else {
                    writeSplitCloseRightTestData(["setupError": "Failed to split right from top-left (iteration \(i))"], at: path)
                    return
                }
                guard let bl = tab.newTerminalSplit(from: topLeftId, orientation: .vertical) else {
                    writeSplitCloseRightTestData(["setupError": "Failed to split down from left (iteration \(i))"], at: path)
                    return
                }
                guard let br = tab.newTerminalSplit(from: tr.id, orientation: .vertical) else {
                    writeSplitCloseRightTestData(["setupError": "Failed to split down from right (iteration \(i))"], at: path)
                    return
                }
                topRight = tr
                bottomLeft = bl
                bottomRight = br
            default:
                // Default: split top/down first, then split left/right in each row.
                guard let bl = tab.newTerminalSplit(from: topLeftId, orientation: .vertical) else {
                    writeSplitCloseRightTestData(["setupError": "Failed to split down from top-left (iteration \(i))"], at: path)
                    return
                }
                guard let br = tab.newTerminalSplit(from: bl.id, orientation: .horizontal) else {
                    writeSplitCloseRightTestData(["setupError": "Failed to split right from bottom-left (iteration \(i))"], at: path)
                    return
                }
                guard let tr = tab.newTerminalSplit(from: topLeftId, orientation: .horizontal) else {
                    writeSplitCloseRightTestData(["setupError": "Failed to split right from top-left (iteration \(i))"], at: path)
                    return
                }
                topRight = tr
                bottomLeft = bl
                bottomRight = br
            }

            // Let newly created surfaces attach before priming content, so sampled panes have
            // stable non-blank text before the close timeline begins.
            try? await Task.sleep(nanoseconds: 180_000_000)

            // Fill left panes with visible content.
            sendText(topLeftId, "printf '\\033[2J\\033[H'; for i in {1..200}; do echo CMUX_SPLIT_TOPLEFT_\(i); done; printf '\\033[HCMUX_MARKER_TOPLEFT\\n'\r")
            sendText(topRight.id, "printf '\\033[2J\\033[H'; for i in {1..200}; do echo CMUX_SPLIT_TOPRIGHT_\(i); done; printf '\\033[HCMUX_MARKER_TOPRIGHT\\n'\r")
            if let bottomLeft {
                sendText(bottomLeft.id, "printf '\\033[2J\\033[H'; for i in {1..200}; do echo CMUX_SPLIT_BOTTOMLEFT_\(i); done; printf '\\033[HCMUX_MARKER_BOTTOMLEFT\\n'\r")
            }
            if let bottomRight {
                sendText(bottomRight.id, "printf '\\033[2J\\033[H'; for i in {1..200}; do echo CMUX_SPLIT_BOTTOMRIGHT_\(i); done; printf '\\033[HCMUX_MARKER_BOTTOMRIGHT\\n'\r")
            }
            // Give shell output a moment to paint before we start the close timeline.
            try? await Task.sleep(nanoseconds: 180_000_000)

            let desiredFrames = max(16, min(burstFrames, 60))
            let closeFrame = min(6, max(1, desiredFrames / 4))
            let delayFrames = max(0, Int((Double(max(0, closeDelayMs)) / 16.6667).rounded(.up)))
            let secondCloseFrame = min(desiredFrames - 1, closeFrame + delayFrames)

            var closeOrder = ""
            let actions: [(frame: Int, action: () -> Void)] = {
                switch pattern {
                case "close_right_single":
                    closeOrder = "TR_ONLY"
                    return [
                        (frame: closeFrame, action: {
                            tab.focusPanel(topRight.id)
                            tab.closePanel(topRight.id, force: true)
                        }),
                    ]
                case "close_bottom":
                    guard let bottomRight, let bottomLeft else { return [] }
                    closeOrder = "BR_THEN_BL"
                    return [
                        (frame: closeFrame, action: {
                            tab.focusPanel(bottomRight.id)
                            tab.closePanel(bottomRight.id, force: true)
                        }),
                        (frame: secondCloseFrame, action: {
                            tab.focusPanel(bottomLeft.id)
                            tab.closePanel(bottomLeft.id, force: true)
                        }),
                    ]
                case "close_right_lrtd_bottom_first", "close_right_bottom_first":
                    guard let bottomRight else { return [] }
                    closeOrder = "BR_THEN_TR"
                    return [
                        (frame: closeFrame, action: {
                            tab.focusPanel(bottomRight.id)
                            tab.closePanel(bottomRight.id, force: true)
                        }),
                        (frame: secondCloseFrame, action: {
                            tab.focusPanel(topRight.id)
                            tab.closePanel(topRight.id, force: true)
                        }),
                    ]
                case "close_right_lrtd_unfocused":
                    guard let bottomRight else { return [] }
                    closeOrder = "TR_THEN_BR_UNFOCUSED"
                    return [
                        (frame: closeFrame, action: {
                            tab.closePanel(topRight.id, force: true)
                        }),
                        (frame: secondCloseFrame, action: {
                            tab.closePanel(bottomRight.id, force: true)
                        }),
                    ]
                default:
                    guard let bottomRight else { return [] }
                    closeOrder = "TR_THEN_BR"
                    return [
                        (frame: closeFrame, action: {
                            tab.focusPanel(topRight.id)
                            tab.closePanel(topRight.id, force: true)
                        }),
                        (frame: secondCloseFrame, action: {
                            tab.focusPanel(bottomRight.id)
                            tab.closePanel(bottomRight.id, force: true)
                        }),
                    ]
                }
            }()

            let targets: [(label: String, view: GhosttySurfaceScrollView)] = {
                switch pattern {
                case "close_right_single":
                    return [
                        ("TL", tab.terminalPanel(for: topLeftId)!.surface.hostedView),
                    ]
                case "close_bottom":
                    return [
                        ("TL", tab.terminalPanel(for: topLeftId)!.surface.hostedView),
                        ("TR", topRight.surface.hostedView),
                    ]
                case "close_right_lrtd_bottom_first", "close_right_bottom_first":
                    return [
                        ("TR", topRight.surface.hostedView),
                        ("TL", tab.terminalPanel(for: topLeftId)!.surface.hostedView),
                    ]
                default:
                    guard let bottomLeft else { return [] }
                    return [
                        ("TL", tab.terminalPanel(for: topLeftId)!.surface.hostedView),
                        ("BL", bottomLeft.surface.hostedView),
                    ]
                }
            }()

            let result = await captureVsyncIOSurfaceTimeline(
                frameCount: desiredFrames,
                closeFrame: closeFrame,
                crop: sampleCrop,
                targets: targets,
                actions: actions
            )

            let paneStateTrace: String = {
                tab.bonsplitController.allPaneIds.map { paneId in
                    let tabs = tab.bonsplitController.tabs(inPane: paneId)
                    let selected = tab.bonsplitController.selectedTab(inPane: paneId)
                    let selectedId = selected.map { String(describing: $0.id) } ?? "nil"
                    let selectedPanelId = selected.flatMap { tab.panelIdFromSurfaceId($0.id) }
                    let selectedPanelLive: String = {
                        guard let selected else { return "0" }
                        return tab.panel(for: selected.id) != nil ? "1" : "0"
                    }()
                    let mappedCount = tabs.filter { tab.panelIdFromSurfaceId($0.id) != nil }.count
                    let selectedPanel = selectedPanelId?.uuidString.prefix(8) ?? "nil"
                    return "pane=\(paneId.id.uuidString.prefix(8)):tabs=\(tabs.count):mapped=\(mappedCount):selected=\(selectedId.prefix(8)):selectedPanel=\(selectedPanel):selectedLive=\(selectedPanelLive)"
                }.joined(separator: ";")
            }()

            writeSplitCloseRightTestData([
                "pattern": pattern,
                "iteration": String(i),
                "closeDelayMs": String(closeDelayMs),
                "closeDelayFrames": String(delayFrames),
                "closeOrder": closeOrder,
                "timelineFrameCount": String(desiredFrames),
                "timelineCloseFrame": String(closeFrame),
                "timelineSecondCloseFrame": String(secondCloseFrame),
                "timelineFirstBlank": result.firstBlank.map { "\($0.label)@\($0.frame)" } ?? "",
                "timelineFirstSizeMismatch": result.firstSizeMismatch.map { "\($0.label)@\($0.frame):ios=\($0.ios):exp=\($0.expected)" } ?? "",
                "timelineTrace": result.trace.joined(separator: "|"),
                "timelinePaneState": paneStateTrace,
                "visualLastIteration": String(i),
            ], at: path)

            if let firstBlank = result.firstBlank {
                writeSplitCloseRightTestData([
                    "blankFrameSeen": "1",
                    "blankObservedIteration": String(i),
                    "blankObservedAt": "\(firstBlank.label)@\(firstBlank.frame)"
                ], at: path)
                return
            }

            if let firstMismatch = result.firstSizeMismatch {
                writeSplitCloseRightTestData([
                    "sizeMismatchSeen": "1",
                    "sizeMismatchObservedIteration": String(i),
                    "sizeMismatchObservedAt": "\(firstMismatch.label)@\(firstMismatch.frame):ios=\(firstMismatch.ios):exp=\(firstMismatch.expected)"
                ], at: path)
                return
            }
        }
	    }

	    @MainActor
	    private func captureVsyncIOSurfaceTimeline(
	        frameCount: Int,
	        closeFrame: Int,
	        crop: CGRect,
	        targets: [(label: String, view: GhosttySurfaceScrollView)],
	        actions: [(frame: Int, action: () -> Void)] = []
	    ) async -> (firstBlank: (label: String, frame: Int)?, firstSizeMismatch: (label: String, frame: Int, ios: String, expected: String)?, trace: [String]) {
	        guard frameCount > 0 else { return (nil, nil, []) }

	        let st = VsyncIOSurfaceTimelineState(frameCount: frameCount, closeFrame: closeFrame)
	        st.scheduledActions = actions.sorted(by: { $0.frame < $1.frame })
	        st.nextActionIndex = 0
	        st.targets = targets.map { t in
	            VsyncIOSurfaceTimelineState.Target(label: t.label, sample: { @MainActor in
	                t.view.debugSampleIOSurface(normalizedCrop: crop)
	            })
	        }

	        let unmanaged = Unmanaged.passRetained(st)
	        let ctx = unmanaged.toOpaque()

	        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
	            st.continuation = cont
	            var link: CVDisplayLink?
	            CVDisplayLinkCreateWithActiveCGDisplays(&link)
	            guard let link else {
	                st.finish()
	                Unmanaged<VsyncIOSurfaceTimelineState>.fromOpaque(ctx).release()
	                return
	            }
	            st.link = link

	            CVDisplayLinkSetOutputCallback(link, cmuxVsyncIOSurfaceTimelineCallback, ctx)
	            CVDisplayLinkStart(link)
	        }

	        return (st.firstBlank, st.firstSizeMismatch, st.trace)
	    }

    private func writeSplitCloseRightTestData(_ updates: [String: String], at path: String) {
        var payload = loadSplitCloseRightTestData(at: path)
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func loadSplitCloseRightTestData(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

    private func setupChildExitSplitUITestIfNeeded() {
        guard !didSetupChildExitSplitUITest else { return }
        didSetupChildExitSplitUITest = true

        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_CHILD_EXIT_SPLIT_SETUP"] == "1" else { return }
        guard let path = env["CMUX_UI_TEST_CHILD_EXIT_SPLIT_PATH"], !path.isEmpty else { return }
        let requestedIterations = Int(env["CMUX_UI_TEST_CHILD_EXIT_SPLIT_ITERATIONS"] ?? "1") ?? 1
        let iterations = max(1, min(requestedIterations, 20))

        func write(_ updates: [String: String]) {
            var payload: [String: String] = {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                    return [:]
                }
                return obj
            }()
            for (k, v) in updates { payload[k] = v }
            guard let out = try? JSONSerialization.data(withJSONObject: payload) else { return }
            try? out.write(to: URL(fileURLWithPath: path), options: .atomic)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Small delay so the initial window/panel has completed first layout.
            try? await Task.sleep(nanoseconds: 200_000_000)

            guard let tab = self.selectedWorkspace else {
                write(["setupError": "Missing selected workspace", "done": "1"])
                return
            }
            write([
                "requestedIterations": String(requestedIterations),
                "iterations": String(iterations),
                "workspaceCountBefore": String(self.tabs.count),
                "panelCountBefore": String(tab.panels.count),
                "done": "0",
            ])

            var completedIterations = 0
            var timedOut = false
            var closedWorkspace = false

            for i in 1...iterations {
                guard self.tabs.contains(where: { $0.id == tab.id }) else {
                    closedWorkspace = true
                    break
                }

                guard let leftPanelId = tab.focusedPanelId ?? tab.panels.keys.first else {
                    write(["setupError": "Missing focused panel before iteration \(i)", "done": "1"])
                    return
                }

                // Start each iteration from a deterministic 1x1 workspace.
                if tab.panels.count > 1 {
                    for panelId in tab.panels.keys where panelId != leftPanelId {
                        tab.closePanel(panelId, force: true)
                    }
                    let collapsed = await self.waitForWorkspacePanelsCondition(
                        tab: tab,
                        timeoutSeconds: 2.0
                    ) { workspace in
                        workspace.panels.count == 1
                    }
                    if !collapsed {
                        write(["setupError": "Timed out collapsing workspace before iteration \(i)", "done": "1"])
                        return
                    }
                }

                guard let rightPanel = tab.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
                    write(["setupError": "Failed to create right split at iteration \(i)", "done": "1"])
                    return
                }

                write([
                    "iteration": String(i),
                    "leftPanelId": leftPanelId.uuidString,
                    "rightPanelId": rightPanel.id.uuidString,
                ])

                tab.focusPanel(rightPanel.id)
                // Wait for the split terminal surface to be attached before sending exit.
                // Without this, very early writes can be dropped during initial surface creation.
                _ = await self.waitForTerminalPanelCondition(
                    tab: tab,
                    panelId: rightPanel.id,
                    timeoutSeconds: 2.0
                ) { panel in
                    panel.surface.isViewInWindow && panel.surface.surface != nil
                }
                // Use an explicit shell exit command for deterministic child-exit behavior across
                // startup timing variance; this still exercises the same SHOW_CHILD_EXITED path.
                rightPanel.sendText("exit\r")

                // Wait for the right panel to close.
                let closed = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                    var cancellable: AnyCancellable?
                    var resolved = false

                    func finish(_ value: Bool) {
                        guard !resolved else { return }
                        resolved = true
                        cancellable?.cancel()
                        cont.resume(returning: value)
                    }

                    cancellable = tab.$panels
                        .map { $0.count }
                        .removeDuplicates()
                        .sink { count in
                            if count == 1 {
                                finish(true)
                            }
                        }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
                        finish(false)
                    }
                }

                if !closed {
                    timedOut = true
                    write(["timedOutIteration": String(i)])
                    break
                }

                if !self.tabs.contains(where: { $0.id == tab.id }) {
                    closedWorkspace = true
                    write(["closedWorkspaceIteration": String(i)])
                    break
                }

                completedIterations = i
            }

            let workspaceStillOpen = self.tabs.contains(where: { $0.id == tab.id })
            let effectiveClosedWorkspace = closedWorkspace || !workspaceStillOpen

            write([
                "workspaceCountAfter": String(self.tabs.count),
                "panelCountAfter": String(tab.panels.count),
                "workspaceStillOpen": workspaceStillOpen ? "1" : "0",
                "closedWorkspace": effectiveClosedWorkspace ? "1" : "0",
                "timedOut": timedOut ? "1" : "0",
                "completedIterations": String(completedIterations),
                "done": "1",
            ])
        }
    }

    private func setupChildExitKeyboardUITestIfNeeded() {
        guard !didSetupChildExitKeyboardUITest else { return }
        didSetupChildExitKeyboardUITest = true

        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP"] == "1" else { return }
        guard let path = env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_PATH"], !path.isEmpty else { return }
        let autoTrigger = env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_AUTO_TRIGGER"] == "1"
        let strictKeyOnly = env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_STRICT"] == "1"
        let triggerMode = (env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_TRIGGER_MODE"] ?? "shell_input")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let useEarlyCtrlShiftTrigger = triggerMode == "early_ctrl_shift_d"
        let useEarlyCtrlDTrigger = triggerMode == "early_ctrl_d"
        let useEarlyTrigger = useEarlyCtrlShiftTrigger || useEarlyCtrlDTrigger
        let triggerUsesShift = triggerMode == "ctrl_shift_d" || useEarlyCtrlShiftTrigger
        let layout = (env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_LAYOUT"] ?? "lr")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedPanelsAfter = max(
            1,
            Int((env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_EXPECTED_PANELS_AFTER"] ?? "1")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            ) ?? 1
        )

        func write(_ updates: [String: String]) {
            var payload: [String: String] = {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                    return [:]
                }
                return obj
            }()
            for (k, v) in updates { payload[k] = v }
            guard let out = try? JSONSerialization.data(withJSONObject: payload) else { return }
            try? out.write(to: URL(fileURLWithPath: path), options: .atomic)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 200_000_000)

            guard let tab = self.selectedWorkspace else {
                write(["setupError": "Missing selected workspace", "done": "1"])
                return
            }
            guard let leftPanelId = tab.focusedPanelId else {
                write(["setupError": "Missing initial focused panel", "done": "1"])
                return
            }
            guard let rightPanel = tab.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
                write(["setupError": "Failed to create right split", "done": "1"])
                return
            }

            var bottomLeftPanelId = ""
            let topRightPanelId = rightPanel.id.uuidString
            var bottomRightPanelId = ""
            var exitPanelId = rightPanel.id

            if layout == "lr_left_vertical" {
                guard let bottomLeft = tab.newTerminalSplit(from: leftPanelId, orientation: .vertical) else {
                    write(["setupError": "Failed to create bottom-left split", "done": "1"])
                    return
                }
                bottomLeftPanelId = bottomLeft.id.uuidString
            } else if layout == "lrtd_close_right_then_exit_top_left" {
                guard let bottomLeft = tab.newTerminalSplit(from: leftPanelId, orientation: .vertical) else {
                    write(["setupError": "Failed to create bottom-left split", "done": "1"])
                    return
                }
                guard let bottomRight = tab.newTerminalSplit(from: rightPanel.id, orientation: .vertical) else {
                    write(["setupError": "Failed to create bottom-right split", "done": "1"])
                    return
                }
                bottomLeftPanelId = bottomLeft.id.uuidString
                bottomRightPanelId = bottomRight.id.uuidString

                // Repro flow: with a 2x2 (left/right then top/down), close both right panes,
                // then trigger Ctrl+D in top-left.
                tab.focusPanel(rightPanel.id)
                tab.closePanel(rightPanel.id, force: true)
                tab.focusPanel(bottomRight.id)
                tab.closePanel(bottomRight.id, force: true)
                exitPanelId = leftPanelId

                let collapsed = await self.waitForWorkspacePanelsCondition(
                    tab: tab,
                    timeoutSeconds: 2.0
                ) { workspace in
                    workspace.panels.count == 2
                }
                if !collapsed {
                    write([
                        "setupError": "Expected 2 panels after closing right column, got \(tab.panels.count)",
                        "done": "1",
                    ])
                    return
                }
            } else if layout == "tdlr_close_bottom_then_exit_top_left" {
                // Alternate repro flow:
                // 1) split top/down
                // 2) split left/right for each row (2x2)
                // 3) close both bottom panes
                // 4) trigger Ctrl+D in top-left
                guard let bottomLeft = tab.newTerminalSplit(from: leftPanelId, orientation: .vertical) else {
                    write(["setupError": "Failed to create bottom-left split", "done": "1"])
                    return
                }
                guard let topRight = tab.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
                    write(["setupError": "Failed to create top-right split", "done": "1"])
                    return
                }
                guard let bottomRight = tab.newTerminalSplit(from: bottomLeft.id, orientation: .horizontal) else {
                    write(["setupError": "Failed to create bottom-right split", "done": "1"])
                    return
                }
                bottomLeftPanelId = bottomLeft.id.uuidString
                bottomRightPanelId = bottomRight.id.uuidString

                // Close every pane except the top row; do it one-by-one and wait for model convergence.
                let keepPanels: Set<UUID> = [leftPanelId, topRight.id]
                for panelId in Array(tab.panels.keys) where !keepPanels.contains(panelId) {
                    tab.focusPanel(panelId)
                    tab.closePanel(panelId, force: true)
                    let closed = await self.waitForWorkspacePanelsCondition(
                        tab: tab,
                        timeoutSeconds: 1.0
                    ) { workspace in
                        workspace.panels[panelId] == nil
                    }
                    if !closed {
                        write([
                            "setupError": "Failed to close bottom pane \(panelId.uuidString)",
                            "done": "1",
                        ])
                        return
                    }
                }
                exitPanelId = leftPanelId

                let collapsed = await self.waitForWorkspacePanelsCondition(
                    tab: tab,
                    timeoutSeconds: 2.0
                ) { workspace in
                    workspace.panels.count == 2
                }
                if !collapsed {
                    write([
                        "setupError": "Expected 2 panels after closing bottom row, got \(tab.panels.count)",
                        "done": "1",
                    ])
                    return
                }
            }

            tab.focusPanel(exitPanelId)
            // Keep child-exit keyboard tests deterministic across user shell configs.
            // `exec cat` exits on a single Ctrl+D and avoids ignore-eof shell settings.
            if let exitPanel = tab.terminalPanel(for: exitPanelId) {
                exitPanel.sendText("exec cat\r")
            }

            var exitPanelAttachedBeforeCtrlD = false
            var exitPanelHasSurfaceBeforeCtrlD = false
            if !useEarlyTrigger {
                let readiness = await self.waitForTerminalPanelReadyForUITest(
                    tab: tab,
                    panelId: exitPanelId
                )
                exitPanelAttachedBeforeCtrlD = readiness.attached
                exitPanelHasSurfaceBeforeCtrlD = readiness.hasSurface
                if !(readiness.attached && readiness.hasSurface) {
                    write([
                        "exitPanelAttachedBeforeCtrlD": readiness.attached ? "1" : "0",
                        "exitPanelHasSurfaceBeforeCtrlD": readiness.hasSurface ? "1" : "0",
                        "setupError": "Exit panel not ready for Ctrl+D (not attached or surface nil)",
                        "done": "1",
                    ])
                    return
                }
                self.ensureFocusedTerminalFirstResponder()
            } else if let exitPanel = tab.terminalPanel(for: exitPanelId) {
                exitPanelAttachedBeforeCtrlD = exitPanel.surface.isViewInWindow
                exitPanelHasSurfaceBeforeCtrlD = exitPanel.surface.surface != nil
            }

            let focusedPanelBefore = tab.focusedPanelId?.uuidString ?? ""
            let firstResponderPanelBefore = tab.panels.compactMap { (panelId, panel) -> UUID? in
                guard let terminal = panel as? TerminalPanel else { return nil }
                return terminal.hostedView.isSurfaceViewFirstResponder() ? panelId : nil
            }.first?.uuidString ?? ""

            write([
                "workspaceId": tab.id.uuidString,
                "leftPanelId": leftPanelId.uuidString,
                "rightPanelId": rightPanel.id.uuidString,
                "topRightPanelId": topRightPanelId,
                "bottomLeftPanelId": bottomLeftPanelId,
                "bottomRightPanelId": bottomRightPanelId,
                "exitPanelId": exitPanelId.uuidString,
                "panelCountBeforeCtrlD": String(tab.panels.count),
                "layout": layout,
                "expectedPanelsAfter": String(expectedPanelsAfter),
                "focusedPanelBefore": focusedPanelBefore,
                "firstResponderPanelBefore": firstResponderPanelBefore,
                "exitPanelAttachedBeforeCtrlD": exitPanelAttachedBeforeCtrlD ? "1" : "0",
                "exitPanelHasSurfaceBeforeCtrlD": exitPanelHasSurfaceBeforeCtrlD ? "1" : "0",
                "ready": "1",
                "done": "0",
            ])

            var finished = false
            var timeoutWork: DispatchWorkItem?

            @MainActor
            func finish(_ updates: [String: String]) {
                guard !finished else { return }
                finished = true
                timeoutWork?.cancel()
                write(updates.merging(["done": "1"], uniquingKeysWith: { _, new in new }))
                self.uiTestCancellables.removeAll()
            }

            tab.$panels
                .map { $0.count }
                .removeDuplicates()
                .sink { [weak self, weak tab] count in
                    Task { @MainActor in
                        guard let self, let tab else { return }
                        if count == expectedPanelsAfter {
                            // Require the post-exit state to be stable for a short window so
                            // we catch "close looked correct, then workspace vanished" races.
                            try? await Task.sleep(nanoseconds: 1_200_000_000)
                            guard tab.panels.count == expectedPanelsAfter else { return }

                            let firstResponderPanelAfter = tab.panels.compactMap { (panelId, panel) -> UUID? in
                                guard let terminal = panel as? TerminalPanel else { return nil }
                                return terminal.hostedView.isSurfaceViewFirstResponder() ? panelId : nil
                            }.first?.uuidString ?? ""

                            finish([
                                "workspaceCountAfter": String(self.tabs.count),
                                "panelCountAfter": String(tab.panels.count),
                                "closedWorkspace": self.tabs.contains(where: { $0.id == tab.id }) ? "0" : "1",
                                "focusedPanelAfter": tab.focusedPanelId?.uuidString ?? "",
                                "firstResponderPanelAfter": firstResponderPanelAfter,
                            ])
                        }
                    }
                }
                .store(in: &uiTestCancellables)

            $tabs
                .map { $0.contains(where: { $0.id == tab.id }) }
                .removeDuplicates()
                .sink { alive in
                    Task { @MainActor in
                        if !alive {
                            finish([
                                "workspaceCountAfter": "0",
                                "panelCountAfter": "0",
                                "closedWorkspace": "1",
                            ])
                        }
                    }
                }
                .store(in: &uiTestCancellables)

            let work = DispatchWorkItem {
                finish([
                    "workspaceCountAfter": String(self.tabs.count),
                    "panelCountAfter": String(tab.panels.count),
                    "closedWorkspace": self.tabs.contains(where: { $0.id == tab.id }) ? "0" : "1",
                    "timedOut": "1",
                ])
            }
            timeoutWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0, execute: work)

            if autoTrigger {
                Task { @MainActor [weak tab] in
                    guard let tab else { return }
                    write(["autoTriggerStarted": "1"])

                    if triggerMode == "runtime_close_callback" {
                        write(["autoTriggerMode": "runtime_close_callback"])
                        self.closePanelAfterChildExited(tabId: tab.id, surfaceId: exitPanelId)
                        return
                    }

                    let triggerModifiers: NSEvent.ModifierFlags = triggerUsesShift
                        ? [.control, .shift]
                        : [.control]
                    let shouldWaitForSurface = !useEarlyTrigger

                    var attachedBeforeTrigger = false
                    var hasSurfaceBeforeTrigger = false
                    if shouldWaitForSurface {
                        let ready = await self.waitForTerminalPanelCondition(
                            tab: tab,
                            panelId: exitPanelId,
                            timeoutSeconds: 5.0
                        ) { panel in
                            attachedBeforeTrigger = panel.surface.isViewInWindow
                            hasSurfaceBeforeTrigger = panel.surface.surface != nil
                            return attachedBeforeTrigger && hasSurfaceBeforeTrigger
                        }
                        if !ready,
                           tab.terminalPanel(for: exitPanelId) == nil {
                            write(["autoTriggerError": "missingExitPanelBeforeTrigger"])
                            return
                        }
                    } else if let panel = tab.terminalPanel(for: exitPanelId) {
                        attachedBeforeTrigger = panel.surface.isViewInWindow
                        hasSurfaceBeforeTrigger = panel.surface.surface != nil
                    }
                    write([
                        "exitPanelAttachedBeforeTrigger": attachedBeforeTrigger ? "1" : "0",
                        "exitPanelHasSurfaceBeforeTrigger": hasSurfaceBeforeTrigger ? "1" : "0",
                    ])
                    if shouldWaitForSurface && !(attachedBeforeTrigger && hasSurfaceBeforeTrigger) {
                        write(["autoTriggerError": "exitPanelNotReadyBeforeTrigger"])
                        return
                    }

                    guard let panel = tab.terminalPanel(for: exitPanelId) else {
                        write(["autoTriggerError": "missingExitPanelAtTrigger"])
                        return
                    }
                    // Exercise the real key path (ghostty_surface_key for Ctrl+D).
                    if panel.hostedView.sendSyntheticCtrlDForUITest(modifierFlags: triggerModifiers) {
                        write(["autoTriggerSentCtrlDKey1": "1"])
                    } else {
                        write([
                            "autoTriggerCtrlDKeyUnavailable": "1",
                            "autoTriggerError": "ctrlDKeyUnavailable",
                        ])
                        return
                    }

                    // In strict mode, never mask routing bugs with fallback writes.
                    if strictKeyOnly {
                        let strictModeLabel: String = {
                            if useEarlyCtrlShiftTrigger { return "strict_early_ctrl_shift_d" }
                            if useEarlyCtrlDTrigger { return "strict_early_ctrl_d" }
                            if triggerUsesShift { return "strict_ctrl_shift_d" }
                            return "strict_ctrl_d"
                        }()
                        write(["autoTriggerMode": strictModeLabel])
                        return
                    }

                    // Non-strict mode keeps one additional Ctrl+D retry for startup timing variance.
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    if tab.panels[exitPanelId] != nil,
                       panel.hostedView.sendSyntheticCtrlDForUITest(modifierFlags: triggerModifiers) {
                        write(["autoTriggerSentCtrlDKey2": "1"])
                    }
                }
            }
        }
    }
#endif
}

extension TabManager {
    func sessionAutosaveFingerprint(
        restorableAgentIndex: RestorableAgentSessionIndex = .empty,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex = .empty
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(selectedTabId)
        hasher.combine(tabs.count)
        let notificationStore = AppDelegate.shared?.notificationStore

        for workspace in tabs.prefix(SessionPersistencePolicy.maxWorkspacesPerWindow) {
            hasher.combine(workspace.id)
            hasher.combine(workspace.focusedPanelId)
            hasher.combine(workspace.currentDirectory)
            hasher.combine(workspace.customTitle ?? "")
            hasher.combine(workspace.customDescription ?? "")
            hasher.combine(workspace.customColor ?? "")
            hasher.combine(workspace.isPinned)
            hasher.combine(workspace.terminalScrollBarHidden)
            hasher.combine(workspace.panels.count)
            hasher.combine(workspace.statusEntries.count)
            hasher.combine(workspace.metadataBlocks.count)
            hasher.combine(workspace.logEntries.count)
            hasher.combine(workspace.panelDirectories.count)
            hasher.combine(workspace.panelTitles.count)
            hasher.combine(workspace.panelPullRequests.count)
            hasher.combine(workspace.panelGitBranches.count)
            hasher.combine(workspace.surfaceListeningPorts.count)
            hasher.combine(notificationStore?.hasManualUnread(forTabId: workspace.id) ?? false)
            hasher.combine(notificationStore?.workspaceIsUnread(forTabId: workspace.id) ?? false)
            Self.hashNotifications(
                notificationStore?.notifications(forTabId: workspace.id, surfaceId: nil) ?? [],
                into: &hasher
            )

            let panelIds = workspace.panels.keys.sorted { $0.uuidString < $1.uuidString }
            hasher.combine(panelIds.count)
            for panelId in panelIds {
                hasher.combine(panelId)
                hasher.combine(workspace.manualUnreadPanelIds.contains(panelId))
                hasher.combine(workspace.restoredUnreadPanelIds.contains(panelId))
                hasher.combine(workspace.restoredUnreadIndicatorContributesToWorkspace(panelId: panelId))
                hasher.combine(
                    notificationStore?.hasVisibleNotificationIndicator(
                        forTabId: workspace.id,
                        surfaceId: panelId
                    ) ?? false
                )
                Self.hashNotifications(
                    notificationStore?.notifications(forTabId: workspace.id, surfaceId: panelId) ?? [],
                    into: &hasher
                )
                Self.hashRestorableAgentSnapshot(
                    restorableAgentIndex.snapshot(
                        workspaceId: workspace.id,
                        panelId: panelId
                    ),
                    into: &hasher
                )
                Self.hashAgentHibernationPanelState(
                    (workspace.panels[panelId] as? TerminalPanel)?.agentHibernationState,
                    into: &hasher
                )
                Self.hashSurfaceResumeBindingSnapshot(
                    workspace.effectiveSurfaceResumeBinding(
                        panelId: panelId,
                        surfaceResumeBindingIndex: surfaceResumeBindingIndex
                    ),
                    into: &hasher
                )
                if let terminalPanel = workspace.terminalPanel(for: panelId) {
                    Self.hashTextBoxDraftSnapshot(
                        terminalPanel.sessionTextBoxDraftSnapshot(),
                        into: &hasher
                    )
                } else {
                    hasher.combine(false)
                }
            }

            if let progress = workspace.progress {
                hasher.combine(Int((progress.value * 1000).rounded()))
                hasher.combine(progress.label)
            } else {
                hasher.combine(-1)
            }

            if let gitBranch = workspace.gitBranch {
                hasher.combine(gitBranch.branch)
                hasher.combine(gitBranch.isDirty)
            } else {
                hasher.combine("")
                hasher.combine(false)
            }
        }

        return hasher.finalize()
    }

    nonisolated static func restorableAgentSnapshotFingerprint(
        _ snapshot: SessionRestorableAgentSnapshot?
    ) -> Int {
        var hasher = Hasher()
        hashRestorableAgentSnapshot(snapshot, into: &hasher)
        return hasher.finalize()
    }

    nonisolated private static func hashRestorableAgentSnapshot(
        _ snapshot: SessionRestorableAgentSnapshot?,
        into hasher: inout Hasher
    ) {
        guard let snapshot else {
            hasher.combine(false)
            return
        }

        hasher.combine(true)
        hasher.combine(snapshot.kind.rawValue)
        hasher.combine(snapshot.sessionId)
        hashOptionalString(snapshot.workingDirectory, into: &hasher)
        hashAgentLaunchCommand(snapshot.launchCommand, into: &hasher)
    }

    nonisolated private static func hashAgentLaunchCommand(
        _ launchCommand: AgentLaunchCommandSnapshot?,
        into hasher: inout Hasher
    ) {
        guard let launchCommand else {
            hasher.combine(false)
            return
        }

        hasher.combine(true)
        hashOptionalString(launchCommand.launcher, into: &hasher)
        hashOptionalString(launchCommand.executablePath, into: &hasher)
        hasher.combine(launchCommand.arguments)
        hashOptionalString(launchCommand.workingDirectory, into: &hasher)
        if let environment = launchCommand.environment {
            hasher.combine(true)
            hasher.combine(environment.count)
            for key in environment.keys.sorted() {
                hasher.combine(key)
                hasher.combine(environment[key])
            }
        } else {
            hasher.combine(false)
        }
        hashOptionalDouble(launchCommand.capturedAt, into: &hasher)
        hashOptionalString(launchCommand.source, into: &hasher)
    }

    private static func hashAgentHibernationPanelState(
        _ state: AgentHibernationPanelState?,
        into hasher: inout Hasher
    ) {
        guard let state else {
            hasher.combine(false)
            return
        }

        hasher.combine(true)
        hashRestorableAgentSnapshot(state.agent, into: &hasher)
        hasher.combine(state.hibernatedAt.timeIntervalSince1970)
        hasher.combine(state.lastActivityAt.timeIntervalSince1970)
    }

    nonisolated private static func hashSurfaceResumeBindingSnapshot(
        _ snapshot: SurfaceResumeBindingSnapshot?,
        into hasher: inout Hasher
    ) {
        guard let snapshot else {
            hasher.combine(false)
            return
        }

        hasher.combine(true)
        hashOptionalString(snapshot.name, into: &hasher)
        hashOptionalString(snapshot.kind, into: &hasher)
        hasher.combine(snapshot.command)
        hashOptionalString(snapshot.cwd, into: &hasher)
        hashOptionalString(snapshot.checkpointId, into: &hasher)
        hashOptionalString(snapshot.source, into: &hasher)
        hashStringMap(snapshot.environment, into: &hasher)
        hasher.combine(snapshot.allowsAutomaticResume)
        if snapshot.isProcessDetected {
            hasher.combine(false)
        } else {
            hashOptionalDouble(snapshot.updatedAt, into: &hasher)
        }
    }

    nonisolated private static func hashTextBoxDraftSnapshot(
        _ snapshot: SessionTextBoxInputDraftSnapshot?,
        into hasher: inout Hasher
    ) {
        guard let snapshot else {
            hasher.combine(false)
            return
        }

        hasher.combine(true)
        hasher.combine(snapshot.isActive)
        hasher.combine(snapshot.parts.count)
        for part in snapshot.parts {
            hasher.combine(part.kind.rawValue)
            hashOptionalString(part.text, into: &hasher)
            hashTextBoxAttachmentSnapshot(part.attachment, into: &hasher)
        }
    }

    nonisolated private static func hashTextBoxAttachmentSnapshot(
        _ snapshot: SessionTextBoxInputAttachmentSnapshot?,
        into hasher: inout Hasher
    ) {
        guard let snapshot else {
            hasher.combine(false)
            return
        }

        hasher.combine(true)
        hasher.combine(snapshot.displayName)
        hasher.combine(snapshot.submissionText)
        hasher.combine(snapshot.submissionPath)
        hashOptionalString(snapshot.localPath, into: &hasher)
        hasher.combine(snapshot.cleanupLocalPathWhenDisposed)
    }

    nonisolated private static func hashNotifications(
        _ notifications: [TerminalNotification],
        into hasher: inout Hasher
    ) {
        hasher.combine(notifications.count)
        for notification in notifications.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            hasher.combine(notification.id)
            hasher.combine(notification.title)
            hasher.combine(notification.subtitle)
            hasher.combine(notification.body)
            hasher.combine(notification.createdAt.timeIntervalSince1970)
            hasher.combine(notification.isRead)
            hasher.combine(notification.paneFlash)
            hasher.combine(notification.panelId)
            hasher.combine(notification.clickAction)
        }
    }

    nonisolated private static func hashOptionalString(_ value: String?, into hasher: inout Hasher) {
        if let value {
            hasher.combine(true)
            hasher.combine(value)
        } else {
            hasher.combine(false)
        }
    }

    nonisolated private static func hashOptionalDouble(_ value: Double?, into hasher: inout Hasher) {
        if let value {
            hasher.combine(true)
            hasher.combine(value)
        } else {
            hasher.combine(false)
        }
    }

    nonisolated private static func hashStringMap(_ value: [String: String]?, into hasher: inout Hasher) {
        guard let value, !value.isEmpty else {
            hasher.combine(false)
            return
        }
        hasher.combine(true)
        let keys = value.keys.sorted()
        hasher.combine(keys.count)
        for key in keys {
            hasher.combine(key)
            hasher.combine(value[key] ?? "")
        }
    }

    func sessionSnapshot(
        includeScrollback: Bool,
        restorableAgentIndex: RestorableAgentSessionIndex = .empty,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex? = nil
    ) -> SessionTabManagerSnapshot {
        let restorableTabs = tabs
            .filter(\.isRestorableInSessionSnapshot)
            .prefix(SessionPersistencePolicy.maxWorkspacesPerWindow)
        let workspaceSnapshots = restorableTabs
            .map {
                $0.sessionSnapshot(
                    includeScrollback: includeScrollback,
                    restorableAgentIndex: restorableAgentIndex,
                    surfaceResumeBindingIndex: surfaceResumeBindingIndex
                )
            }
        let selectedWorkspaceIndex = selectedTabId.flatMap { selectedTabId in
            restorableTabs.firstIndex(where: { $0.id == selectedTabId })
        }
        return SessionTabManagerSnapshot(
            selectedWorkspaceIndex: selectedWorkspaceIndex,
            workspaces: workspaceSnapshots
        )
    }

    func sessionSnapshotWorkspaceIds() -> [UUID] {
        Array(
            tabs
                .filter(\.isRestorableInSessionSnapshot)
                .prefix(SessionPersistencePolicy.maxWorkspacesPerWindow)
                .map(\.id)
        )
    }

    private func releaseRestoredAwayWorkspace(_ workspace: Workspace) {
        // Session restore replaces the bootstrap workspace objects with freshly
        // restored ones. Tear the old graph down after the atomic swap so late
        // panel/socket callbacks cannot keep mutating hidden pre-restore state.
        AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: workspace.id)
        workspace.teardownAllPanels()
        workspace.teardownRemoteConnection()
        workspace.owningTabManager = nil
    }

    @discardableResult
    func restoreSessionSnapshot(_ snapshot: SessionTabManagerSnapshot) -> [[UUID: UUID]] {
        let previousTabs = tabs
        for tab in previousTabs {
            unwireClosedBrowserTracking(for: tab)
        }
        ClosedItemHistoryStore.shared.removePanelRecords(
            forWorkspaceIds: Set(previousTabs.map(\.id))
        )
        let existingProbeKeys = Set(workspaceGitProbeStateByKey.keys)
            .union(workspaceGitProbeTimersByKey.keys)
        for key in existingProbeKeys {
            clearWorkspaceGitProbe(key)
        }
        workspaceGitTrackedDirectoryByKey.removeAll()
        updateWorkspaceGitMetadataFallbackTimer()
        resetWorkspacePullRequestRefreshState()

        // Clear non-@Published state without touching tabs/selectedTabId yet.
        lastFocusedPanelByTab.removeAll()
        pendingPanelTitleUpdates.removeAll()
        focusHistory.removeAll()
        historyIndex = -1
        focusHistoryRecordingSuppressionDepth = 0
        focusHistorySuppressedSelectionSideEffectGenerations.removeAll()
        focusHistoryRevision &+= 1
        pendingWorkspaceUnfocusTarget = nil
        workspaceCycleCooldownTask?.cancel()
        workspaceCycleCooldownTask = nil
        isWorkspaceCycleHot = false
        selectionSideEffectsGeneration &+= 1
        recentlyClosedBrowsers = RecentlyClosedBrowserStack(capacity: 20)

        // Build the new workspace list locally to avoid intermediate @Published
        // emissions (empty tabs, nil selectedTabId) that can leave SwiftUI's
        // mountedWorkspaceIds empty and cause a frozen blank launch state (#399).
        var newTabs: [Workspace] = []
        var restoredPanelIdsByWorkspaceIndex: [[UUID: UUID]] = []
        let workspaceSnapshots = snapshot.workspaces
            .prefix(SessionPersistencePolicy.maxWorkspacesPerWindow)
        for workspaceSnapshot in workspaceSnapshots {
            let ordinal = Self.nextPortOrdinal
            Self.nextPortOrdinal += 1
            let workspace = Workspace(
                title: workspaceSnapshot.processTitle,
                workingDirectory: workspaceSnapshot.currentDirectory,
                portOrdinal: ordinal
            )
            workspace.owningTabManager = self
            let restoredPanelIds = workspace.restoreSessionSnapshot(workspaceSnapshot)
            wireClosedBrowserTracking(for: workspace)
            newTabs.append(workspace)
            restoredPanelIdsByWorkspaceIndex.append(restoredPanelIds)
        }

        if newTabs.isEmpty {
            let ordinal = Self.nextPortOrdinal
            Self.nextPortOrdinal += 1
            let fallback = Workspace(title: "Terminal 1", portOrdinal: ordinal)
            fallback.owningTabManager = self
            wireClosedBrowserTracking(for: fallback)
            newTabs.append(fallback)
        }

        // Determine selection before mutating @Published properties.
        let newSelectedId: UUID?
        if let selectedWorkspaceIndex = snapshot.selectedWorkspaceIndex,
           newTabs.indices.contains(selectedWorkspaceIndex) {
            newSelectedId = newTabs[selectedWorkspaceIndex].id
        } else {
            newSelectedId = newTabs.first?.id
        }

        // Single atomic assignment of @Published properties so SwiftUI observers
        // never see an intermediate state with empty tabs or nil selection.
        tabs = newTabs
        selectedTabId = newSelectedId
        let existingIds = Set(newTabs.map(\.id))
        pruneBackgroundWorkspaceLoads(existingIds: existingIds)
        sidebarSelectedWorkspaceIds.formIntersection(existingIds)
        for workspace in previousTabs {
            releaseRestoredAwayWorkspace(workspace)
        }
        for workspace in newTabs {
            let terminalPanels = workspace.panels.values.compactMap { $0 as? TerminalPanel }
            for terminalPanel in terminalPanels {
                scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
                    workspaceId: workspace.id,
                    panelId: terminalPanel.id
                )
            }
        }

        if let selectedTabId {
            NotificationCenter.default.post(
                name: .ghosttyDidFocusTab,
                object: nil,
                userInfo: [GhosttyNotificationKey.tabId: selectedTabId]
            )
        }
        return restoredPanelIdsByWorkspaceIndex
    }

    func remapClosedPanelHistoryAfterWindowRestore(
        originalWorkspaceIds: [UUID],
        restoredPanelIdsByWorkspaceIndex: [[UUID: UUID]]
    ) {
        guard !originalWorkspaceIds.isEmpty else { return }
        let count = min(originalWorkspaceIds.count, tabs.count)
        guard count > 0 else { return }
        for index in 0..<count {
            let panelIdMap = restoredPanelIdsByWorkspaceIndex.indices.contains(index)
                ? restoredPanelIdsByWorkspaceIndex[index]
                : [:]
            ClosedItemHistoryStore.shared.remapPanelWorkspaceIds(
                from: originalWorkspaceIds[index],
                to: tabs[index].id,
                panelIdMap: panelIdMap
            )
        }
    }
}

extension Notification.Name {
    static let commandPaletteToggleRequested = Notification.Name("cmux.commandPaletteToggleRequested")
    static let commandPaletteRequested = Notification.Name("cmux.commandPaletteRequested")
    static let commandPaletteSwitcherRequested = Notification.Name("cmux.commandPaletteSwitcherRequested")
    static let commandPaletteSubmitRequested = Notification.Name("cmux.commandPaletteSubmitRequested")
    static let commandPaletteDismissRequested = Notification.Name("cmux.commandPaletteDismissRequested")
    static let commandPaletteRenameTabRequested = Notification.Name("cmux.commandPaletteRenameTabRequested")
    static let commandPaletteRenameWorkspaceRequested = Notification.Name("cmux.commandPaletteRenameWorkspaceRequested")
    static let commandPaletteEditWorkspaceDescriptionRequested = Notification.Name("cmux.commandPaletteEditWorkspaceDescriptionRequested")
    static let commandPaletteMoveSelection = Notification.Name("cmux.commandPaletteMoveSelection")
    static let commandPaletteRenameInputInteractionRequested = Notification.Name("cmux.commandPaletteRenameInputInteractionRequested")
    static let commandPaletteRenameInputDeleteBackwardRequested = Notification.Name("cmux.commandPaletteRenameInputDeleteBackwardRequested")
    static let feedbackComposerRequested = Notification.Name("cmux.feedbackComposerRequested")
    static let ghosttyDidSetTitle = Notification.Name("ghosttyDidSetTitle")
    static let ghosttyDidFocusTab = Notification.Name("ghosttyDidFocusTab")
    static let ghosttyDidFocusSurface = Notification.Name("ghosttyDidFocusSurface")
    static let ghosttyDidBecomeFirstResponderSurface = Notification.Name("ghosttyDidBecomeFirstResponderSurface")
    static let browserDidBecomeFirstResponderWebView = Notification.Name("browserDidBecomeFirstResponderWebView")
    static let browserFocusAddressBar = Notification.Name("browserFocusAddressBar")
    static let browserMoveOmnibarSelection = Notification.Name("browserMoveOmnibarSelection")
    static let browserDidExitAddressBar = Notification.Name("browserDidExitAddressBar")
    static let browserDidFocusAddressBar = Notification.Name("browserDidFocusAddressBar")
    static let browserDidBlurAddressBar = Notification.Name("browserDidBlurAddressBar")
    static let webViewDidReceiveClick = Notification.Name("webViewDidReceiveClick")
    static let terminalPortalVisibilityDidChange = Notification.Name("cmux.terminalPortalVisibilityDidChange")
    static let browserPortalRegistryDidChange = Notification.Name("cmux.browserPortalRegistryDidChange")
    static let workspaceOrderDidChange = Notification.Name("cmux.workspaceOrderDidChange")
    static let tabManagerFocusHistoryRevisionDidChange = Notification.Name("cmux.tabManagerFocusHistoryRevisionDidChange")
}

enum BrowserFirstResponderNotificationUserInfoKey {
    static let pointerInitiated = "pointerInitiated"
}
