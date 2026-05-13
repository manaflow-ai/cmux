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

extension SyncedHostWindow: Sendable {}

struct SyncedWindowSlotFrame: Equatable, Sendable {
    let quartzFrame: CGRect
    let cocoaFrame: CGRect
    let owningWindowNumber: Int
}

private enum SyncedWindowActionResult: Equatable, Sendable {
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

private struct SyncedWindowAccessibilityController: Sendable {
    var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    @MainActor
    func requestPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @MainActor
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

        let paneFrame = targetFrame.integral
        if readFrame(from: axWindow)?.size.isApproximatelyEqual(to: paneFrame.size) != true {
            let sizeResult = setSize(paneFrame.size, on: axWindow)
            guard sizeResult == .success else {
                return .failed(sizeResult)
            }
        }

        if readFrame(from: axWindow)?.origin.isApproximatelyEqual(to: paneFrame.origin) != true {
            let positionResult = setPosition(paneFrame.origin, on: axWindow)
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

}

@MainActor
private final class SyncedWindowProjectionController {
    private struct PlacementRequest: Sendable {
        let generation: UInt64
        let window: SyncedHostWindow
        let slot: SyncedWindowSlotFrame
        let raise: Bool
        let reportFailures: Bool
    }

    private let accessibilityController = SyncedWindowAccessibilityController()
    private var targetWindow: SyncedHostWindow?
    private var targetSlot: SyncedWindowSlotFrame?
    private var isPointerInTarget = false
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var placementGeneration: UInt64 = 0
    private var pendingPlacementRequest: PlacementRequest?
    private var isPlacementRunning = false
    var onPlacementResult: ((SyncedWindowActionResult, Bool) -> Void)?

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
        placementGeneration &+= 1
        pendingPlacementRequest = nil
    }

    func place(window: SyncedHostWindow, in slot: SyncedWindowSlotFrame, raise: Bool, reportFailures: Bool) {
        targetWindow = window
        targetSlot = slot
        installMouseMonitors()
        isPointerInTarget = slot.cocoaFrame.contains(NSEvent.mouseLocation)
        placementGeneration &+= 1
        pendingPlacementRequest = PlacementRequest(
            generation: placementGeneration,
            window: window,
            slot: slot,
            raise: raise,
            reportFailures: reportFailures
        )
        drainPlacementRequests()
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
        guard isInside != isPointerInTarget else {
            return
        }

        isPointerInTarget = isInside
        if isInside {
            _ = raiseTarget()
        } else {
            NSApp.activate(ignoringOtherApps: true)
            keepTargetAboveOwningWindow()
        }
    }

    private func drainPlacementRequests() {
        guard !isPlacementRunning, let request = pendingPlacementRequest else {
            return
        }

        pendingPlacementRequest = nil
        isPlacementRunning = true
        let accessibilityController = accessibilityController
        Task.detached(priority: request.raise ? .userInitiated : .userInteractive) { [weak self] in
            let result = accessibilityController.place(
                request.window,
                frame: request.slot.quartzFrame,
                raise: request.raise
            )
            await self?.finishPlacementRequest(request, result: result)
        }
    }

    private func finishPlacementRequest(_ request: PlacementRequest, result: SyncedWindowActionResult) {
        isPlacementRunning = false
        let isCurrent = request.generation == placementGeneration && targetWindow?.id == request.window.id
        if isCurrent {
            targetSlot = request.slot
            if result == .succeeded {
                keepTargetAboveOwningWindow()
            }
            onPlacementResult?(result, request.reportFailures)
        }
        drainPlacementRequests()
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
    private var accessibilityStatusObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var accessibilityRecheckMouseMonitor: Any?

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
        projectionController.onPlacementResult = { [weak self] result, reportFailures in
            self?.handlePlacementResult(result, reportFailures: reportFailures)
        }
        installAccessibilityStatusObservers()
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

        if isSynced {
            isSynced = false
            projectionController.stop()
        }
        selectedWindowID = windows.first?.id
        updateTitleForSelection()
    }

    func selectWindow(_ id: CGWindowID?) {
        selectedWindowID = id
        updateTitleForSelection()
        if isSynced, let selectedWindow {
            projectionController.start(window: selectedWindow)
            placeSelectedWindow(reportFailures: true, raise: true)
        }
    }

    func syncWindow(_ id: CGWindowID) {
        selectedWindowID = id
        updateTitleForSelection()
        syncSelectedWindow()
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
        placeSelectedWindow(reportFailures: true, raise: true)
        updateTitleForSelection()
    }

    func detach() {
        isSynced = false
        projectionController.stop()
        statusMessage = String(localized: "syncedWindow.status.detached", defaultValue: "Pane detached.")
        statusIsError = false
        updateTitleForSelection()
    }

    func returnToWindowList() {
        isSynced = false
        projectionController.stop()
        statusMessage = nil
        statusIsError = false
        updateTitleForSelection()
    }

    func updateSlotFrame(_ frame: SyncedWindowSlotFrame) {
        guard slotFrame != frame else {
            return
        }
        slotFrame = frame
        projectionController.updateSlot(frame)
        placeSelectedWindow(reportFailures: false, raise: false)
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

    func copyAppPathToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(appBundlePath, forType: .string)
        statusMessage = String(localized: "syncedWindow.status.appPathCopied", defaultValue: "App path copied.")
        statusIsError = false
    }

    func checkAccessibilityPermission() {
        refreshAccessibilityStatus()
        if accessibilityTrusted {
            statusMessage = String(localized: "syncedWindow.status.accessibilityReady", defaultValue: "Accessibility ready.")
            statusIsError = false
            placeSelectedWindow(reportFailures: true, raise: true)
        } else {
            statusMessage = String(localized: "syncedWindow.status.accessibilityMissing", defaultValue: "Accessibility permission is needed to sync windows.")
            statusIsError = true
        }
    }

    func refreshAccessibilityStatus() {
        accessibilityTrusted = accessibilityController.isTrusted
        updateAccessibilityRecheckMouseMonitor()
    }

    var appBundlePath: String {
        Bundle.main.bundleURL.path
    }

    func focus() {
        if isSynced, let selectedWindow {
            projectionController.start(window: selectedWindow)
            _ = projectionController.raiseTarget()
        }
    }

    func unfocus() {}

    func close() {
        removeAccessibilityStatusObservers()
        projectionController.stop()
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    private func placeSelectedWindow(reportFailures: Bool, raise: Bool) {
        guard isSynced, let selectedWindow, let slotFrame else {
            return
        }

        projectionController.place(
            window: selectedWindow,
            in: slotFrame,
            raise: raise,
            reportFailures: reportFailures
        )
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

    private func installAccessibilityStatusObservers() {
        guard accessibilityStatusObservers.isEmpty else {
            return
        }

        let appCenter = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        accessibilityStatusObservers = [
            (
                appCenter,
                appCenter.addObserver(
                    forName: NSApplication.didBecomeActiveNotification,
                    object: NSApp,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.handleAccessibilityStatusSignal()
                    }
                }
            ),
            (
                appCenter,
                appCenter.addObserver(
                    forName: NSWindow.didBecomeKeyNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.handleAccessibilityStatusSignal()
                    }
                }
            ),
            (
                workspaceCenter,
                workspaceCenter.addObserver(
                    forName: NSWorkspace.didActivateApplicationNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.handleAccessibilityStatusSignal()
                    }
                }
            ),
        ]
    }

    private func removeAccessibilityStatusObservers() {
        for (center, observer) in accessibilityStatusObservers {
            center.removeObserver(observer)
        }
        accessibilityStatusObservers.removeAll()
        removeAccessibilityRecheckMouseMonitor()
    }

    private func handleAccessibilityStatusSignal() {
        let wasTrusted = accessibilityTrusted
        refreshAccessibilityStatus()
        guard accessibilityTrusted != wasTrusted else {
            return
        }

        if accessibilityTrusted {
            statusMessage = String(localized: "syncedWindow.status.accessibilityReady", defaultValue: "Accessibility ready.")
            statusIsError = false
            reloadWindows()
        } else {
            isSynced = false
            projectionController.stop()
            statusMessage = String(localized: "syncedWindow.status.accessibilityMissing", defaultValue: "Accessibility permission is needed to sync windows.")
            statusIsError = true
        }
    }

    private func updateAccessibilityRecheckMouseMonitor() {
        if accessibilityTrusted {
            removeAccessibilityRecheckMouseMonitor()
            return
        }

        guard accessibilityRecheckMouseMonitor == nil else {
            return
        }

        accessibilityRecheckMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleAccessibilityStatusSignal()
            }
        }
    }

    private func removeAccessibilityRecheckMouseMonitor() {
        if let accessibilityRecheckMouseMonitor {
            NSEvent.removeMonitor(accessibilityRecheckMouseMonitor)
        }
        accessibilityRecheckMouseMonitor = nil
    }
}

struct SyncedWindowPanelView: View {
    @ObservedObject var panel: SyncedWindowPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onRequestPanelFocus: () -> Void

    var body: some View {
        ZStack {
            if panel.isAccessibilityTrusted {
                syncedWindowFlow
            } else {
                fullPaneAccessibilityOnboarding
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            panel.refreshAccessibilityStatus()
            if isVisibleInUI {
                panel.reloadWindows()
            }
        }
    }

    private var syncedWindowFlow: some View {
        Group {
            if panel.isSynced, let selectedWindow = panel.selectedWindow {
                syncedWindowPage(selectedWindow)
            } else {
                windowPickerPage
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var windowPickerPage: some View {
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

            if panel.windows.isEmpty {
                ContentUnavailableView(
                    String(localized: "syncedWindow.empty.title", defaultValue: "Select a window"),
                    systemImage: "macwindow"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(panel.windows) { window in
                    Button {
                        panel.syncWindow(window.id)
                        onRequestPanelFocus()
                    } label: {
                        SyncedWindowRow(window: window, showsDisclosure: true)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func syncedWindowPage(_ selectedWindow: SyncedHostWindow) -> some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                selectedWindowPlaceholder(selectedWindow)
                SyncedWindowDockView(onFrameChange: panel.updateSlotFrame, slotInset: 0)
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(
                        isEffectivelySynced ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.35),
                        style: StrokeStyle(lineWidth: 1, dash: isEffectivelySynced ? [7, 5] : [])
                    )
                    .allowsHitTesting(false)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                panel.returnToWindowList()
            } label: {
                Label(
                    String(localized: "syncedWindow.button.allWindows", defaultValue: "All Windows"),
                    systemImage: "chevron.left"
                )
            }
            .buttonStyle(.borderless)

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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var fullPaneAccessibilityOnboarding: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            accessibilityOnboardingContent
        }
    }

    private var accessibilityOnboardingContent: some View {
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
            Text(String(localized: "syncedWindow.onboarding.findAppInstructions", defaultValue: "If cmux is missing, copy the app path, then press Command-Shift-G in the file picker and paste it."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
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
                    panel.copyAppPathToClipboard()
                } label: {
                    Label(
                        String(localized: "syncedWindow.button.copyAppPath", defaultValue: "Copy App Path"),
                        systemImage: "doc.on.doc"
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
            if let statusMessage = panel.statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(panel.statusIsError ? Color.red : .secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
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
                : String(localized: "syncedWindow.placeholder.preview", defaultValue: "Select a window to align it here.")
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
    var showsDisclosure = false

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
            Spacer()
            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 6)
    }
}

private struct SyncedWindowDockView: NSViewRepresentable {
    let onFrameChange: (SyncedWindowSlotFrame) -> Void
    var slotInset: CGFloat = 14

    func makeNSView(context: Context) -> SyncedWindowDockNSView {
        let view = SyncedWindowDockNSView()
        view.onFrameChange = onFrameChange
        view.slotInset = slotInset
        return view
    }

    func updateNSView(_ nsView: SyncedWindowDockNSView, context: Context) {
        nsView.onFrameChange = onFrameChange
        nsView.slotInset = slotInset
        nsView.reportFrame()
    }
}

private final class SyncedWindowDockNSView: NSView {
    var onFrameChange: ((SyncedWindowSlotFrame) -> Void)?
    var slotInset: CGFloat = 14 {
        didSet {
            reportFrame()
        }
    }

    private var lastFrame: SyncedWindowSlotFrame?
    private var windowMoveObserver: NSObjectProtocol?
    private var windowResizeObserver: NSObjectProtocol?
    private var mouseUpMonitor: Any?

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
        installMouseUpMonitor()
        reportFrame()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            removeWindowObservers()
            removeMouseUpMonitor()
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

        let insetBounds = bounds.insetBy(dx: slotInset, dy: slotInset)
        guard insetBounds.width > 0, insetBounds.height > 0 else {
            return
        }

        let windowRect = convert(insetBounds, to: nil)
        let cocoaFrame = window.convertToScreen(windowRect)
        let slotFrame = SyncedWindowSlotFrame(
            quartzFrame: quartzFrame(fromCocoaFrame: cocoaFrame),
            cocoaFrame: cocoaFrame,
            owningWindowNumber: window.windowNumber
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

    private func installMouseUpMonitor() {
        guard mouseUpMonitor == nil else {
            return
        }

        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp]) { [weak self] event in
            Task { @MainActor in
                self?.reportFrame()
            }
            return event
        }
    }

    private func removeMouseUpMonitor() {
        if let mouseUpMonitor {
            NSEvent.removeMonitor(mouseUpMonitor)
        }
        mouseUpMonitor = nil
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
