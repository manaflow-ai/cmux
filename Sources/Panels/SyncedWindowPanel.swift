import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Darwin
import SwiftUI

struct SyncedHostWindow: Identifiable, Equatable, Hashable {
    let id: CGWindowID
    let ownerPID: pid_t
    let ownerName: String
    let title: String
    let frame: CGRect
    let layer: Int
    let alpha: Double
    let isOnScreen: Bool

    var hasTitle: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var displayTitle: String {
        hasTitle ? title : String(localized: "syncedWindow.window.untitled", defaultValue: "Untitled")
    }

    var area: CGFloat {
        frame.width * frame.height
    }

    static func == (lhs: SyncedHostWindow, rhs: SyncedHostWindow) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    init?(windowInfo: [String: Any]) {
        guard
            let windowIDNumber = windowInfo[kCGWindowNumber as String] as? NSNumber,
            let ownerPIDNumber = windowInfo[kCGWindowOwnerPID as String] as? NSNumber,
            let ownerName = windowInfo[kCGWindowOwnerName as String] as? String,
            let boundsDictionary = windowInfo[kCGWindowBounds as String] as? NSDictionary,
            let frame = CGRect(dictionaryRepresentation: boundsDictionary)
        else {
            return nil
        }

        let title = windowInfo[kCGWindowName as String] as? String ?? ""
        let layer = (windowInfo[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        let alpha = (windowInfo[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
        let isOnScreen = (windowInfo[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
        guard frame.width >= 80, frame.height >= 60, alpha > 0 else {
            return nil
        }

        self.id = CGWindowID(windowIDNumber.uint32Value)
        self.ownerPID = pid_t(ownerPIDNumber.int32Value)
        self.ownerName = ownerName
        self.title = title
        self.frame = frame
        self.layer = layer
        self.alpha = alpha
        self.isOnScreen = isOnScreen
    }
}

struct SyncedWindowSlotFrame: Equatable {
    let quartzFrame: CGRect
    let cocoaFrame: CGRect
    let owningWindowNumber: Int
    let isLiveResize: Bool
}

private enum SyncedWindowActionResult: Equatable {
    case succeeded
    case accessibilityPermissionMissing
    case windowUnavailable
    case failed(AXError)
}

private struct SyncedHostWindowEnumerator {
    private let currentProcessID = getpid()

    func windows() -> [SyncedHostWindow] {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let rawWindows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return rawWindows
            .compactMap(SyncedHostWindow.init(windowInfo:))
            .filter(isUsableWindow)
            .sorted(by: sortWindows)
    }

    private func isUsableWindow(_ window: SyncedHostWindow) -> Bool {
        window.ownerPID != currentProcessID
            && window.layer == 0
            && (window.isOnScreen || window.hasTitle)
    }

    private func sortWindows(_ lhs: SyncedHostWindow, _ rhs: SyncedHostWindow) -> Bool {
        if lhs.isOnScreen != rhs.isOnScreen {
            return lhs.isOnScreen
        }
        if lhs.ownerName == rhs.ownerName {
            return lhs.area > rhs.area
        }
        return lhs.ownerName.localizedStandardCompare(rhs.ownerName) == .orderedAscending
    }
}

@MainActor
private struct SyncedWindowAccessibilityController {
    var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    func requestPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func raise(_ window: SyncedHostWindow) -> SyncedWindowActionResult {
        guard isTrusted else {
            return .accessibilityPermissionMissing
        }

        let app = AXUIElementCreateApplication(window.ownerPID)
        guard let axWindow = resolveAXWindow(for: window, app: app) else {
            return .windowUnavailable
        }

        let frontmostResult = setFrontmost(app)
        guard frontmostResult == .success else {
            return .failed(frontmostResult)
        }
        let raiseResult = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        return raiseResult == .success ? .succeeded : .failed(raiseResult)
    }

    func place(_ window: SyncedHostWindow, frame targetFrame: CGRect, raise: Bool) -> SyncedWindowActionResult {
        guard isTrusted else {
            return .accessibilityPermissionMissing
        }

        let app = AXUIElementCreateApplication(window.ownerPID)
        var axWindow = resolveAXWindow(for: window, app: app)
        if axWindow == nil, raise {
            let frontmostResult = setFrontmost(app)
            guard frontmostResult == .success else {
                return .failed(frontmostResult)
            }
            axWindow = resolveAXWindow(for: window, app: app)
        }

        guard let axWindow else {
            return .windowUnavailable
        }

        if raise {
            let frontmostResult = setFrontmost(app)
            guard frontmostResult == .success else {
                return .failed(frontmostResult)
            }
            _ = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        }

        let fittedFrame = fittedFrame(for: readFrame(from: axWindow)?.size ?? window.frame.size, inside: targetFrame.integral)
        if readFrame(from: axWindow)?.size.isApproximatelyEqual(to: fittedFrame.size) != true {
            let sizeResult = setSize(fittedFrame.size, on: axWindow)
            guard sizeResult == .success else {
                return .failed(sizeResult)
            }
        }

        if readFrame(from: axWindow)?.origin.isApproximatelyEqual(to: fittedFrame.origin) != true {
            let positionResult = setPosition(fittedFrame.origin, on: axWindow)
            guard positionResult == .success else {
                return .failed(positionResult)
            }
        }

        if raise {
            _ = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        }
        return .succeeded
    }

    private func resolveAXWindow(for window: SyncedHostWindow, app: AXUIElement) -> AXUIElement? {
        guard let axWindows = axWindows(for: app), !axWindows.isEmpty else {
            return nil
        }

        if window.hasTitle, let matchingTitle = axWindows.first(where: { readStringAttribute(kAXTitleAttribute, from: $0) == window.title }) {
            return matchingTitle
        }

        if let matchingFrame = axWindows.first(where: { candidate in
            guard let frame = readFrame(from: candidate) else {
                return false
            }
            return abs(frame.width - window.frame.width) < 8
                && abs(frame.height - window.frame.height) < 8
                && abs(frame.minX - window.frame.minX) < 12
                && abs(frame.minY - window.frame.minY) < 12
        }) {
            return matchingFrame
        }

        return axWindows.first
    }

    private func axWindows(for app: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard result == .success else {
            return nil
        }
        return value as? [AXUIElement]
    }

    private func readStringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else {
            return nil
        }
        return value as? String
    }

    private func readFrame(from element: AXUIElement) -> CGRect? {
        guard let position = readPointAttribute(kAXPositionAttribute, from: element),
              let size = readSizeAttribute(kAXSizeAttribute, from: element)
        else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private func readPointAttribute(_ attribute: String, from element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else {
            return nil
        }

        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else {
            return nil
        }
        return point
    }

    private func readSizeAttribute(_ attribute: String, from element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgSize else {
            return nil
        }

        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else {
            return nil
        }
        return size
    }

    private func setPosition(_ position: CGPoint, on element: AXUIElement) -> AXError {
        var mutablePosition = position
        guard let value = AXValueCreate(.cgPoint, &mutablePosition) else {
            return .cannotComplete
        }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    private func setSize(_ size: CGSize, on element: AXUIElement) -> AXError {
        var mutableSize = size
        guard let value = AXValueCreate(.cgSize, &mutableSize) else {
            return .cannotComplete
        }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }

    private func setFrontmost(_ app: AXUIElement) -> AXError {
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    private func fittedFrame(for windowSize: CGSize, inside containerFrame: CGRect) -> CGRect {
        guard windowSize.width > 0, windowSize.height > 0 else {
            return containerFrame
        }

        let scale = min(containerFrame.width / windowSize.width, containerFrame.height / windowSize.height, 1)
        let fittedSize = CGSize(
            width: max((windowSize.width * scale).rounded(.down), 1),
            height: max((windowSize.height * scale).rounded(.down), 1)
        )
        return CGRect(
            x: containerFrame.midX - fittedSize.width / 2,
            y: containerFrame.midY - fittedSize.height / 2,
            width: fittedSize.width,
            height: fittedSize.height
        ).integral
    }
}

@MainActor
private final class SyncedWindowProjectionController {
    private let accessibilityController = SyncedWindowAccessibilityController()
    private var targetWindow: SyncedHostWindow?
    private var targetSlot: SyncedWindowSlotFrame?
    private var isPointerInTarget = false
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?

    func start(window: SyncedHostWindow) {
        targetWindow = window
        installMouseMonitors()
    }

    func updateSlot(_ slot: SyncedWindowSlotFrame) {
        targetSlot = slot
    }

    func stop() {
        removeMouseMonitors()
        targetWindow = nil
        targetSlot = nil
        isPointerInTarget = false
    }

    func place(window: SyncedHostWindow, in slot: SyncedWindowSlotFrame) -> SyncedWindowActionResult {
        targetWindow = window
        targetSlot = slot
        installMouseMonitors()
        isPointerInTarget = slot.cocoaFrame.contains(NSEvent.mouseLocation)
        let result = accessibilityController.place(window, frame: slot.quartzFrame, raise: true)
        if result == .succeeded {
            keepTargetAboveOwningWindow()
        }
        return result
    }

    func raiseTarget() -> SyncedWindowActionResult {
        guard let targetWindow else {
            return .windowUnavailable
        }
        let result = accessibilityController.raise(targetWindow)
        if result == .succeeded {
            keepTargetAboveOwningWindow()
        }
        return result
    }

    private func installMouseMonitors() {
        guard globalMouseMonitor == nil, localMouseMonitor == nil else {
            return
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor in
                self?.updateFocusForPointer()
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            Task { @MainActor in
                self?.updateFocusForPointer()
            }
            return event
        }
    }

    private func removeMouseMonitors() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
        }
        globalMouseMonitor = nil
        localMouseMonitor = nil
    }

    private func updateFocusForPointer() {
        guard let targetWindow, let targetSlot else {
            return
        }

        let isInside = targetSlot.cocoaFrame.contains(NSEvent.mouseLocation)
        keepTargetAboveOwningWindow()

        guard isInside != isPointerInTarget else {
            return
        }

        isPointerInTarget = isInside
        if isInside {
            _ = raiseTarget()
        }
    }

    private func keepTargetAboveOwningWindow() {
        guard let targetWindow, let targetSlot else {
            return
        }

        guard let owningWindow = NSApp.windows.first(where: { $0.windowNumber == targetSlot.owningWindowNumber }) else {
            return
        }

        owningWindow.order(.below, relativeTo: Int(targetWindow.id))
    }
}

@MainActor
final class SyncedWindowPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .syncedWindow
    private(set) var workspaceId: UUID

    @Published private(set) var windows: [SyncedHostWindow] = []
    @Published var selectedWindowID: CGWindowID?
    @Published private(set) var isSynced = false
    @Published private(set) var displayTitle: String
    @Published private(set) var statusMessage: String?
    @Published private(set) var statusIsError = false
    @Published private(set) var focusFlashToken: Int = 0
    @Published private(set) var accessibilityTrusted = false

    private let enumerator = SyncedHostWindowEnumerator()
    private let accessibilityController = SyncedWindowAccessibilityController()
    private let projectionController = SyncedWindowProjectionController()
    private var slotFrame: SyncedWindowSlotFrame?

    var displayIcon: String? {
        "rectangle.inset.filled.and.person.filled"
    }

    var selectedWindow: SyncedHostWindow? {
        guard let selectedWindowID else {
            return nil
        }
        return windows.first(where: { $0.id == selectedWindowID })
    }

    var isAccessibilityTrusted: Bool {
        accessibilityTrusted
    }

    init(workspaceId: UUID) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.displayTitle = String(localized: "syncedWindow.title", defaultValue: "Synced Window")
        reloadWindows()
    }

    func updateWorkspaceId(_ workspaceId: UUID) {
        self.workspaceId = workspaceId
    }

    func reloadWindows() {
        refreshAccessibilityStatus()
        windows = enumerator.windows()
        if let selectedWindowID, windows.contains(where: { $0.id == selectedWindowID }) {
            updateTitleForSelection()
            if isSynced, let selectedWindow {
                projectionController.start(window: selectedWindow)
            }
            return
        }

        selectedWindowID = windows.first?.id
        updateTitleForSelection()
    }

    func selectWindow(_ id: CGWindowID?) {
        selectedWindowID = id
        updateTitleForSelection()
        if isSynced, let selectedWindow {
            projectionController.start(window: selectedWindow)
            placeSelectedWindow(reportFailures: true)
        }
    }

    func syncSelectedWindow() {
        refreshAccessibilityStatus()
        guard accessibilityTrusted else {
            isSynced = false
            projectionController.stop()
            statusMessage = String(localized: "syncedWindow.status.accessibilityMissing", defaultValue: "Accessibility permission is needed to sync windows.")
            statusIsError = true
            return
        }

        guard let selectedWindow else {
            statusMessage = String(localized: "syncedWindow.status.noWindow", defaultValue: "Select a window first.")
            statusIsError = true
            return
        }

        isSynced = true
        projectionController.start(window: selectedWindow)
        placeSelectedWindow(reportFailures: true)
        updateTitleForSelection()
    }

    func detach() {
        isSynced = false
        projectionController.stop()
        statusMessage = String(localized: "syncedWindow.status.detached", defaultValue: "Pane detached.")
        statusIsError = false
        updateTitleForSelection()
    }

    func updateSlotFrame(_ frame: SyncedWindowSlotFrame) {
        guard slotFrame != frame else {
            return
        }
        slotFrame = frame
        projectionController.updateSlot(frame)
        guard !frame.isLiveResize else {
            return
        }
        placeSelectedWindow(reportFailures: false)
    }

    func requestAccessibilityPermission() {
        accessibilityController.requestPermission()
        refreshAccessibilityStatus()
        if !accessibilityTrusted {
            accessibilityController.openAccessibilitySettings()
        }
        statusMessage = String(localized: "syncedWindow.status.accessibilityRequested", defaultValue: "Accessibility permission requested.")
        statusIsError = false
    }

    func checkAccessibilityPermission() {
        refreshAccessibilityStatus()
        if accessibilityTrusted {
            statusMessage = String(localized: "syncedWindow.status.accessibilityReady", defaultValue: "Accessibility ready.")
            statusIsError = false
            placeSelectedWindow(reportFailures: true)
        } else {
            statusMessage = String(localized: "syncedWindow.status.accessibilityMissing", defaultValue: "Accessibility permission is needed to sync windows.")
            statusIsError = true
        }
    }

    func refreshAccessibilityStatus() {
        accessibilityTrusted = accessibilityController.isTrusted
    }

    func focus() {
        if isSynced, let selectedWindow {
            projectionController.start(window: selectedWindow)
            _ = projectionController.raiseTarget()
        }
    }

    func unfocus() {}

    func close() {
        projectionController.stop()
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    private func placeSelectedWindow(reportFailures: Bool) {
        guard isSynced, let selectedWindow, let slotFrame else {
            return
        }

        let result = projectionController.place(window: selectedWindow, in: slotFrame)
        handlePlacementResult(result, reportFailures: reportFailures)
    }

    private func handlePlacementResult(_ result: SyncedWindowActionResult, reportFailures: Bool) {
        switch result {
        case .succeeded:
            statusMessage = String(localized: "syncedWindow.status.synced", defaultValue: "Window synced to pane.")
            statusIsError = false
        case .accessibilityPermissionMissing:
            accessibilityTrusted = false
            isSynced = false
            projectionController.stop()
            statusMessage = String(localized: "syncedWindow.status.accessibilityMissing", defaultValue: "Accessibility permission is needed to sync windows.")
            statusIsError = true
        case .windowUnavailable:
            guard reportFailures else { return }
            statusMessage = String(localized: "syncedWindow.status.windowUnavailable", defaultValue: "Window unavailable.")
            statusIsError = true
        case .failed(let error):
            guard reportFailures || !error.isTransientSyncedWindowPlacementError else { return }
            let format = String(localized: "syncedWindow.status.actionFailed", defaultValue: "Window action failed: %@")
            statusMessage = String(format: format, String(describing: error))
            statusIsError = true
        }
    }

    private func updateTitleForSelection() {
        if let selectedWindow {
            displayTitle = selectedWindow.ownerName
        } else {
            displayTitle = String(localized: "syncedWindow.title", defaultValue: "Synced Window")
        }
    }
}

struct SyncedWindowPanelView: View {
    @ObservedObject var panel: SyncedWindowPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onRequestPanelFocus: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            windowList
                .frame(minWidth: 210, idealWidth: 250, maxWidth: 300)
                .background(Color(nsColor: .underPageBackgroundColor))

            Divider()

            syncedPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            panel.refreshAccessibilityStatus()
            if isVisibleInUI {
                panel.reloadWindows()
            }
        }
    }

    private var windowList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(String(localized: "syncedWindow.sidebar.title", defaultValue: "Windows"))
                    .font(.headline)
                Spacer()
                Button {
                    panel.reloadWindows()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "syncedWindow.refresh.help", defaultValue: "Refresh windows"))
            }
            .padding(12)

            List(selection: Binding(
                get: { panel.selectedWindowID },
                set: { panel.selectWindow($0) }
            )) {
                ForEach(panel.windows) { window in
                    SyncedWindowRow(window: window)
                        .tag(Optional(window.id))
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var syncedPane: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                if !panel.isAccessibilityTrusted {
                    accessibilityOnboarding
                } else if let selectedWindow = panel.selectedWindow {
                    selectedWindowPlaceholder(selectedWindow)
                    SyncedWindowDockView(onFrameChange: panel.updateSlotFrame)
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(
                            isEffectivelySynced ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.35),
                            style: StrokeStyle(lineWidth: 1, dash: isEffectivelySynced ? [7, 5] : [])
                        )
                        .padding(14)
                        .allowsHitTesting(false)
                } else {
                    ContentUnavailableView(
                        String(localized: "syncedWindow.empty.title", defaultValue: "Select a window"),
                        systemImage: "macwindow"
                    )
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: headerIconName)
                .foregroundStyle(headerIconColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(panel.selectedWindow?.displayTitle ?? String(localized: "syncedWindow.title", defaultValue: "Synced Window"))
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !panel.isAccessibilityTrusted {
                Button {
                    panel.requestAccessibilityPermission()
                } label: {
                    Label(
                        String(localized: "syncedWindow.button.openSettings", defaultValue: "Open Settings"),
                        systemImage: "gearshape"
                    )
                }
            }
            Button {
                panel.isSynced ? panel.detach() : panel.syncSelectedWindow()
                onRequestPanelFocus()
            } label: {
                Label(
                    panel.isSynced
                        ? String(localized: "syncedWindow.button.detach", defaultValue: "Detach")
                        : String(localized: "syncedWindow.button.sync", defaultValue: "Sync Into Pane"),
                    systemImage: panel.isSynced ? "rectangle.portrait.and.arrow.right" : "link"
                )
            }
            .disabled(panel.selectedWindow == nil || !panel.isAccessibilityTrusted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var accessibilityOnboarding: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.orange)
            Text(String(localized: "syncedWindow.onboarding.title", defaultValue: "Enable Accessibility"))
                .font(.title3.weight(.semibold))
            Text(String(localized: "syncedWindow.onboarding.message", defaultValue: "cmux needs Accessibility permission to move and raise the selected app window."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack(spacing: 10) {
                Button {
                    panel.requestAccessibilityPermission()
                } label: {
                    Label(
                        String(localized: "syncedWindow.button.openSettings", defaultValue: "Open Settings"),
                        systemImage: "gearshape"
                    )
                }
                Button {
                    panel.checkAccessibilityPermission()
                } label: {
                    Label(
                        String(localized: "syncedWindow.button.checkAgain", defaultValue: "Check Again"),
                        systemImage: "arrow.clockwise"
                    )
                }
            }
        }
        .padding(28)
    }

    private var headerSubtitle: String {
        if let statusMessage = panel.statusMessage {
            return statusMessage
        }
        if !panel.isAccessibilityTrusted {
            return String(localized: "syncedWindow.status.accessibilityRequired", defaultValue: "Accessibility permission required.")
        }
        if let selectedWindow = panel.selectedWindow {
            let format = String(localized: "syncedWindow.subtitle.selected", defaultValue: "%@ window %@")
            return String(format: format, selectedWindow.ownerName, String(selectedWindow.id))
        }
        return String(localized: "syncedWindow.subtitle.empty", defaultValue: "Choose an app window to sync")
    }

    private var isEffectivelySynced: Bool {
        panel.isAccessibilityTrusted && panel.isSynced
    }

    private var headerIconName: String {
        if !panel.isAccessibilityTrusted {
            return "exclamationmark.triangle.fill"
        }
        if panel.statusIsError {
            return "exclamationmark.triangle.fill"
        }
        if panel.isSynced {
            return "link.circle.fill"
        }
        return "macwindow"
    }

    private var headerIconColor: Color {
        if !panel.isAccessibilityTrusted {
            return .orange
        }
        if panel.statusIsError {
            return .red
        }
        if panel.isSynced {
            return .green
        }
        return .secondary
    }

    private func selectedWindowPlaceholder(_ selectedWindow: SyncedHostWindow) -> some View {
        VStack(spacing: 10) {
            Image(systemName: isEffectivelySynced ? "rectangle.inset.filled" : "rectangle.dashed")
                .font(.system(size: 34))
                .foregroundStyle(isEffectivelySynced ? Color.accentColor : .secondary)
            Text(selectedWindow.ownerName)
                .font(.title3.weight(.semibold))
            Text(isEffectivelySynced
                ? String(localized: "syncedWindow.placeholder.synced", defaultValue: "The native app window is aligned here.")
                : String(localized: "syncedWindow.placeholder.preview", defaultValue: "Press Sync Into Pane to align the native app window here.")
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 340)
        }
        .padding(28)
    }
}

private struct SyncedWindowRow: View {
    let window: SyncedHostWindow

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: window.isOnScreen ? "macwindow" : "macwindow.badge.plus")
                .foregroundStyle(window.isOnScreen ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(window.displayTitle)
                    .lineLimit(1)
                Text(window.ownerName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct SyncedWindowDockView: NSViewRepresentable {
    let onFrameChange: (SyncedWindowSlotFrame) -> Void

    func makeNSView(context: Context) -> SyncedWindowDockNSView {
        let view = SyncedWindowDockNSView()
        view.onFrameChange = onFrameChange
        return view
    }

    func updateNSView(_ nsView: SyncedWindowDockNSView, context: Context) {
        nsView.onFrameChange = onFrameChange
        nsView.reportFrame()
    }
}

private final class SyncedWindowDockNSView: NSView {
    var onFrameChange: ((SyncedWindowSlotFrame) -> Void)?

    private var lastFrame: SyncedWindowSlotFrame?
    private var windowMoveObserver: NSObjectProtocol?
    private var windowResizeObserver: NSObjectProtocol?

    override var isFlipped: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        installWindowObservers()
        reportFrame()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            removeWindowObservers()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func layout() {
        super.layout()
        reportFrame()
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        reportFrame()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        reportFrame()
    }

    func reportFrame() {
        guard let window, bounds.width > 0, bounds.height > 0 else {
            return
        }

        let insetBounds = bounds.insetBy(dx: 14, dy: 14)
        guard insetBounds.width > 0, insetBounds.height > 0 else {
            return
        }

        let windowRect = convert(insetBounds, to: nil)
        let cocoaFrame = window.convertToScreen(windowRect)
        let slotFrame = SyncedWindowSlotFrame(
            quartzFrame: quartzFrame(fromCocoaFrame: cocoaFrame),
            cocoaFrame: cocoaFrame,
            owningWindowNumber: window.windowNumber,
            isLiveResize: inLiveResize
        )

        guard lastFrame != slotFrame else {
            return
        }

        lastFrame = slotFrame
        Task { @MainActor [onFrameChange] in
            onFrameChange?(slotFrame)
        }
    }

    private func installWindowObservers() {
        removeWindowObservers()
        guard let window else {
            return
        }

        let center = NotificationCenter.default
        windowMoveObserver = center.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reportFrame()
            }
        }
        windowResizeObserver = center.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reportFrame()
            }
        }
    }

    private func removeWindowObservers() {
        let center = NotificationCenter.default
        if let windowMoveObserver {
            center.removeObserver(windowMoveObserver)
        }
        if let windowResizeObserver {
            center.removeObserver(windowResizeObserver)
        }
        windowMoveObserver = nil
        windowResizeObserver = nil
    }

    private func quartzFrame(fromCocoaFrame frame: CGRect) -> CGRect {
        guard let screen = NSScreen.screens.max(by: { lhs, rhs in
            lhs.frame.intersection(frame).area < rhs.frame.intersection(frame).area
        }) else {
            return frame
        }

        let displayFrame = displayBounds(for: screen)
        let screenFrame = screen.frame
        return CGRect(
            x: displayFrame.minX + (frame.minX - screenFrame.minX),
            y: displayFrame.minY + (screenFrame.maxY - frame.maxY),
            width: frame.width,
            height: frame.height
        ).integral
    }

    private func displayBounds(for screen: NSScreen) -> CGRect {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return screen.frame
        }
        return CGDisplayBounds(CGDirectDisplayID(displayID.uint32Value))
    }
}

private extension AXError {
    var isTransientSyncedWindowPlacementError: Bool {
        self == .failure || self == .cannotComplete
    }
}

private extension CGSize {
    func isApproximatelyEqual(to other: CGSize) -> Bool {
        abs(width - other.width) < 1 && abs(height - other.height) < 1
    }
}

private extension CGPoint {
    func isApproximatelyEqual(to other: CGPoint) -> Bool {
        abs(x - other.x) < 1 && abs(y - other.y) < 1
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else {
            return 0
        }
        return width * height
    }
}
