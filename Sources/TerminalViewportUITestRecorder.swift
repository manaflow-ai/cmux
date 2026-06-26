#if DEBUG
import AppKit
import CmuxTestSupport
import Foundation
import CmuxTerminal

@MainActor
final class TerminalViewportUITestRecorder {
    private struct RecorderContext {
        let window: NSWindow
        let context: AppDelegate.RegisteredMainWindow
        let terminalPanel: TerminalPanel
    }

    private let environment: [String: String]
    private let contextProvider: () -> [AppDelegate.RegisteredMainWindow]
    /// Resolves a window's per-window ``SidebarState`` by `WindowID` through the
    /// app delegate's `windowSidebarStates` store. Injected (not read off a
    /// singleton) so the recorder never assumes which `AppDelegate` is live; the
    /// per-window sidebar state was peeled out of `MainWindowContext` into the
    /// `WindowID`-keyed store (owner ruling 2026-06-18).
    private let sidebarStateProvider: (AppDelegate.RegisteredMainWindow) -> SidebarState
    /// Resolves a window's per-window ``FileExplorerState`` by `WindowID` through
    /// the app delegate's `windowFileExplorerStates` store, or `nil` when the
    /// window has none. Injected like ``sidebarStateProvider`` so the recorder
    /// never assumes which `AppDelegate` is live; the per-window file-explorer
    /// state was peeled out of `MainWindowContext` into the `WindowID`-keyed
    /// store (owner ruling 2026-06-18).
    private let fileExplorerStateProvider: (AppDelegate.RegisteredMainWindow) -> FileExplorerState?
    private let initialWindowSize: NSSize?
    private let initialWindowSizeText: String?
    private let resizeWindowSize: NSSize?
    private let resizeWindowSizeText: String?
    private let hideSidebar: Bool
    private let hideRightSidebar: Bool
    private let deadline: Date
    private var didRecordReadyGeometry = false
    private var didRecordInitialGeometry = false
    private var timer: DispatchSourceTimer?

    static func isEnabled(environment: [String: String]) -> Bool {
        guard environment["CMUX_UI_TEST_TERMINAL_VIEWPORT_SETUP"] == "1",
              environment["CMUX_UI_TEST_TERMINAL_VIEWPORT_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return false
        }
        return true
    }

    init(
        environment: [String: String],
        contextProvider: @escaping () -> [AppDelegate.RegisteredMainWindow],
        sidebarStateProvider: @escaping (AppDelegate.RegisteredMainWindow) -> SidebarState,
        fileExplorerStateProvider: @escaping (AppDelegate.RegisteredMainWindow) -> FileExplorerState?
    ) {
        self.environment = environment
        self.contextProvider = contextProvider
        self.sidebarStateProvider = sidebarStateProvider
        self.fileExplorerStateProvider = fileExplorerStateProvider
        initialWindowSize = Self.parseWindowSize(environment["CMUX_UI_TEST_TERMINAL_VIEWPORT_WINDOW_SIZE"])
        initialWindowSizeText = Self.requestedWindowSizeText(environment["CMUX_UI_TEST_TERMINAL_VIEWPORT_WINDOW_SIZE"])
        resizeWindowSize = Self.parseWindowSize(environment["CMUX_UI_TEST_TERMINAL_VIEWPORT_RESIZE_WINDOW_SIZE"])
        resizeWindowSizeText = Self.requestedWindowSizeText(environment["CMUX_UI_TEST_TERMINAL_VIEWPORT_RESIZE_WINDOW_SIZE"])
        hideSidebar = environment["CMUX_UI_TEST_TERMINAL_VIEWPORT_HIDE_SIDEBAR"] == "1"
        hideRightSidebar = environment["CMUX_UI_TEST_TERMINAL_VIEWPORT_HIDE_RIGHT_SIDEBAR"] == "1"
        deadline = Date().addingTimeInterval(20)
    }

    deinit {
        timer?.cancel()
    }

    func start() {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.tick()
            }
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        guard Date() < deadline else {
            if !didRecordReadyGeometry {
                writeData(["terminalViewportSetupError": "Timed out waiting for terminal viewport"])
                stop()
            }
            return
        }
        guard let recorderContext = currentContext() else {
            return
        }

        let window = recorderContext.window
        let context = recorderContext.context
        let terminalPanel = recorderContext.terminalPanel
        let requestedWindowSize = didRecordInitialGeometry
            ? (resizeWindowSize ?? initialWindowSize)
            : initialWindowSize
        let requestedWindowSizeText = didRecordInitialGeometry
            ? (resizeWindowSizeText ?? initialWindowSizeText)
            : initialWindowSizeText

        let sidebarState = sidebarStateProvider(context)
        let fileExplorerState = fileExplorerStateProvider(context)
        if hideSidebar {
            sidebarState.isVisible = false
        }
        if hideRightSidebar {
            fileExplorerState?.setVisible(false)
        }
        if let requestedWindowSize {
            Self.setWindowSize(requestedWindowSize, on: window)
        }

        window.contentView?.layoutSubtreeIfNeeded()
        TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: window)
        TerminalWindowPortalRegistry.synchronizeExternalGeometryNow(for: window)
        terminalPanel.hostedView.superview?.layoutSubtreeIfNeeded()
        terminalPanel.hostedView.layoutSubtreeIfNeeded()
        terminalPanel.surface.forceRefresh(reason: "uiTest.terminalViewport")
        didRecordReadyGeometry = true

        var viewportData = Self.hostedGeometry(terminalPanel: terminalPanel)
        var recorderData: [String: String] = [
            "terminalViewportReady": "1",
            "terminalViewportWindowWidth": Self.format(window.frame.width),
            "terminalViewportWindowHeight": Self.format(window.frame.height),
            "terminalViewportSidebarVisible": sidebarState.isVisible ? "1" : "0",
            "terminalViewportRightSidebarVisible": fileExplorerState?.isVisible == true ? "1" : "0",
            "terminalViewportWorkspaceId": terminalPanel.workspaceId.uuidString,
        ]
        if let requestedWindowSizeText {
            recorderData["terminalViewportRequestedWindowSize"] = requestedWindowSizeText
        }
        viewportData.merge(recorderData) { _, newValue in newValue }
        writeData(viewportData)
        if !didRecordInitialGeometry {
            didRecordInitialGeometry = true
            writeData(Self.prefixedData(viewportData, prefix: "terminalViewportInitial"))
        } else if resizeWindowSize != nil {
            writeData(Self.prefixedData(viewportData, prefix: "terminalViewportResized"))
        }
    }

    private func currentContext() -> RecorderContext? {
        for context in contextProvider() {
            guard let window = context.window else { continue }
            guard let workspace = context.tabManager.selectedWorkspace ?? context.tabManager.tabs.first else { continue }
            guard let terminalPanel = workspace.focusedTerminalPanel
                    ?? workspace.panels.values.compactMap({ $0 as? TerminalPanel }).first else {
                continue
            }
            guard terminalPanel.hostedView.window != nil,
                  terminalPanel.hostedView.bounds.width > 0,
                  terminalPanel.hostedView.bounds.height > 0 else {
                continue
            }
            return RecorderContext(window: window, context: context, terminalPanel: terminalPanel)
        }
        return nil
    }

    private func writeData(_ updates: [String: String]) {
        _ = UITestCaptureSink().mutateJSONObjectIfConfigured(envKey: "CMUX_UI_TEST_TERMINAL_VIEWPORT_PATH") { payload in
            for (key, value) in updates {
                payload[key] = value
            }
        }
    }

    private static func parseWindowSize(_ rawValue: String?) -> NSSize? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else { return nil }
        let parts = rawValue
            .split(separator: "x", maxSplits: 1)
            .compactMap { Double(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard parts.count == 2 else { return nil }
        return NSSize(width: max(320, parts[0]), height: max(240, parts[1]))
    }

    private static func requestedWindowSizeText(_ rawValue: String?) -> String? {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func setWindowSize(_ requestedSize: NSSize, on window: NSWindow) {
        let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        let clampedSize: NSSize
        if let screenFrame {
            clampedSize = NSSize(
                width: min(requestedSize.width, screenFrame.width - 80),
                height: min(requestedSize.height, screenFrame.height - 80)
            )
        } else {
            clampedSize = requestedSize
        }
        let origin = NSPoint(
            x: screenFrame.map { $0.minX + 40 } ?? window.frame.minX,
            y: screenFrame.map { $0.maxY - 40 - clampedSize.height } ?? window.frame.minY
        )
        let frame = NSRect(origin: origin, size: clampedSize)
        if !window.frame.equalTo(frame) {
            window.setFrame(frame, display: true)
        }
    }

    private static func hostedGeometry(terminalPanel: TerminalPanel) -> [String: String] {
        let hostedView = terminalPanel.hostedView
        let hostedFrame = hostedView.frame
        let hostedBounds = hostedView.bounds
        let hostedSuperviewBounds = hostedView.superview?.bounds ?? .zero
        let windowContentBounds = hostedView.window?.contentView?.bounds ?? .zero
        let hostedFrameInContent: NSRect
        if let contentView = hostedView.window?.contentView {
            hostedFrameInContent = contentView.convert(hostedView.convert(hostedView.bounds, to: nil), from: nil)
        } else {
            hostedFrameInContent = .zero
        }

        return [
            "terminalViewportPanelId": terminalPanel.id.uuidString,
            "terminalViewportPanelWidth": format(hostedSuperviewBounds.width),
            "terminalViewportPanelHeight": format(hostedSuperviewBounds.height),
            "terminalViewportHostedFrameMinX": format(hostedFrame.minX),
            "terminalViewportHostedFrameMinY": format(hostedFrame.minY),
            "terminalViewportHostedFrameMaxX": format(hostedFrame.maxX),
            "terminalViewportHostedFrameMaxY": format(hostedFrame.maxY),
            "terminalViewportHostedFrameWidth": format(hostedFrame.width),
            "terminalViewportHostedFrameHeight": format(hostedFrame.height),
            "terminalViewportHostedBoundsWidth": format(hostedBounds.width),
            "terminalViewportHostedBoundsHeight": format(hostedBounds.height),
            "terminalViewportHostedSuperviewWidth": format(hostedSuperviewBounds.width),
            "terminalViewportHostedSuperviewHeight": format(hostedSuperviewBounds.height),
            "terminalViewportWindowContentWidth": format(windowContentBounds.width),
            "terminalViewportWindowContentHeight": format(windowContentBounds.height),
            "terminalViewportHostedContentMinX": format(hostedFrameInContent.minX),
            "terminalViewportHostedContentMinY": format(hostedFrameInContent.minY),
            "terminalViewportHostedContentMaxX": format(hostedFrameInContent.maxX),
            "terminalViewportHostedContentMaxY": format(hostedFrameInContent.maxY),
        ]
    }

    private static func prefixedData(_ data: [String: String], prefix: String) -> [String: String] {
        var prefixedData: [String: String] = [:]
        let basePrefix = "terminalViewport"
        for (key, value) in data where key.hasPrefix(basePrefix) {
            let suffix = key.dropFirst(basePrefix.count)
            prefixedData["\(prefix)\(suffix)"] = value
        }
        return prefixedData
    }

    private static func format(_ value: CGFloat) -> String {
        String(format: "%.3f", Double(value))
    }
}
#endif
