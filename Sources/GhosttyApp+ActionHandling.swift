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


// MARK: - Ghostty action callback handling
extension GhosttyApp {
    // SAFETY: Ghostty C callbacks can run while GhosttyApp.shared is still initializing.
    // cmux owns one process-lifetime GhosttyApp, so the registry avoids singleton re-entry
    // without adding a teardown path for a ghostty_app_t that is never freed/recreated.
    private static let appRegistryLock = NSLock()
    private static var appRegistry: [UInt: GhosttyApp] = [:]
    private static var initializingRuntimeApp: GhosttyApp?
    private func bellFeatures() -> CUnsignedInt {
        guard let config else { return 0 }
        var features: CUnsignedInt = 0
        let key = "bell-features"
        _ = ghostty_config_get(config, &features, key, UInt(key.lengthOfBytes(using: .utf8)))
        return features
    }

    private func bellAudioPath() -> String? {
        guard let config else { return nil }
        var value: UnsafePointer<Int8>?
        let key = "bell-audio-path"
        guard ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8))),
              let rawPath = value else {
            return nil
        }
        let path = String(cString: rawPath)
        return path.isEmpty ? nil : path
    }

    private func bellAudioVolume() -> Float {
        guard let config else { return 0.5 }
        var value: Double = 0.5
        let key = "bell-audio-volume"
        _ = ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8)))
        return Float(min(1.0, max(0.0, value)))
    }

    private func ringBell() {
        let features = bellFeatures()

        if (features & (1 << 0)) != 0 {
            NSSound.beep()
        }

        if (features & (1 << 1)) != 0,
           let path = bellAudioPath(),
           let sound = NSSound(contentsOfFile: path, byReference: false) {
            sound.volume = bellAudioVolume()
            bellAudioSound = sound
            if !sound.play() {
                bellAudioSound = nil
            }
        }

        if (features & (1 << 2)) != 0 {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    func logThemeAction(_ message: String) {
        guard backgroundLogEnabled else { return }
        logBackground("theme action \(message)")
    }

    private func actionLabel(for action: ghostty_action_s) -> String {
        switch action.tag {
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            return "reload_config"
        case GHOSTTY_ACTION_CONFIG_CHANGE:
            return "config_change"
        case GHOSTTY_ACTION_COLOR_CHANGE:
            return "color_change"
        default:
            return String(describing: action.tag)
        }
    }

    private func logAction(_ action: ghostty_action_s, target: ghostty_target_s, tabId: UUID?, surfaceId: UUID?) {
        guard backgroundLogEnabled else { return }
        let targetLabel = target.tag == GHOSTTY_TARGET_SURFACE ? "surface" : "app"
        logBackground(
            "action event target=\(targetLabel) action=\(actionLabel(for: action)) tab=\(tabId?.uuidString ?? "nil") surface=\(surfaceId?.uuidString ?? "nil")"
        )
    }

    private func color(from change: ghostty_action_color_change_s) -> NSColor {
        NSColor(
            red: CGFloat(change.r) / 255,
            green: CGFloat(change.g) / 255,
            blue: CGFloat(change.b) / 255,
            alpha: 1.0
        )
    }

    private func colorKindLabel(_ kind: ghostty_action_color_kind_e) -> String {
        switch kind {
        case GHOSTTY_ACTION_COLOR_KIND_FOREGROUND:
            return "foreground"
        case GHOSTTY_ACTION_COLOR_KIND_BACKGROUND:
            return "background"
        case GHOSTTY_ACTION_COLOR_KIND_CURSOR:
            return "cursor"
        default:
            return "palette:\(kind.rawValue)"
        }
    }

    @MainActor
    private func applyAppColorChange(
        _ change: ghostty_action_color_change_s,
        source: String
    ) {
        let newColor = color(from: change)
        switch change.kind {
        case GHOSTTY_ACTION_COLOR_KIND_BACKGROUND:
            applyDefaultBackground(
                color: newColor,
                opacity: defaultBackgroundOpacity,
                backgroundBlur: defaultBackgroundBlur,
                source: source,
                scope: .app
            )
            DispatchQueue.main.async {
                self.applyBackgroundToKeyWindow()
            }
        case GHOSTTY_ACTION_COLOR_KIND_FOREGROUND:
            applyDefaultBackground(
                color: defaultBackgroundColor,
                opacity: defaultBackgroundOpacity,
                backgroundBlur: defaultBackgroundBlur,
                foregroundColor: newColor,
                source: source,
                scope: .app
            )
        case GHOSTTY_ACTION_COLOR_KIND_CURSOR:
            applyDefaultBackground(
                color: defaultBackgroundColor,
                opacity: defaultBackgroundOpacity,
                backgroundBlur: defaultBackgroundBlur,
                cursorColor: newColor,
                source: source,
                scope: .app
            )
        default:
            if backgroundLogEnabled {
                logBackground(
                    "app color change ignored kind=\(colorKindLabel(change.kind)) color=\(newColor.hexString()) source=\(source)"
                )
            }
        }
    }

    private func performOnMain<T>(_ work: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { work() }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { work() }
        }
    }

    @MainActor
    private static func openEmbeddedBrowserLink(
        url: URL,
        sourceWorkspaceId: UUID,
        sourcePanelId: UUID,
        host: String
    ) -> Bool {
        guard BrowserAvailabilitySettings.isEnabled() else {
            #if DEBUG
            cmuxDebugLog("link.openURL deferred embedded but cmuxBrowser=disabled, opening externally url=\(url)")
            #endif
            return NSWorkspace.shared.open(url)
        }

        guard let app = AppDelegate.shared,
              let resolved = app.workspaceContainingPanel(
                panelId: sourcePanelId,
                preferredWorkspaceId: sourceWorkspaceId
              ) else {
            #if DEBUG
            cmuxDebugLog(
                "link.openURL deferred embedded but workspace lookup failed, opening externally " +
                "tabId=\(sourceWorkspaceId) surfaceId=\(sourcePanelId) url=\(url)"
            )
            #endif
            return NSWorkspace.shared.open(url)
        }

        let workspace = resolved.workspace
        #if DEBUG
        if workspace.id != sourceWorkspaceId {
            cmuxDebugLog(
                "link.openURL workspace.remap sourceTab=\(sourceWorkspaceId) " +
                "resolvedTab=\(workspace.id) surfaceId=\(sourcePanelId)"
            )
        }
        #endif

        let openedInBrowser: Bool
        if let targetPane = workspace.preferredRightSideTargetPane(fromPanelId: sourcePanelId) {
            #if DEBUG
            cmuxDebugLog("link.openURL opening in existing browser pane=\(targetPane)")
            #endif
            openedInBrowser = workspace.newBrowserSurface(inPane: targetPane, url: url, focus: true) != nil
        } else {
            #if DEBUG
            cmuxDebugLog("link.openURL opening as new browser split from surface=\(sourcePanelId)")
            #endif
            openedInBrowser = workspace.newBrowserSplit(from: sourcePanelId, orientation: .horizontal, url: url) != nil
        }

        guard openedInBrowser else {
            #if DEBUG
            cmuxDebugLog(
                "link.openURL deferred embedded browser creation failed, opening externally " +
                "host=\(host) url=\(url)"
            )
            #endif
            return NSWorkspace.shared.open(url)
        }

        return true
    }

    private func splitDirection(from direction: ghostty_action_split_direction_e) -> SplitDirection? {
        switch direction {
        case GHOSTTY_SPLIT_DIRECTION_RIGHT: return .right
        case GHOSTTY_SPLIT_DIRECTION_LEFT: return .left
        case GHOSTTY_SPLIT_DIRECTION_DOWN: return .down
        case GHOSTTY_SPLIT_DIRECTION_UP: return .up
        default: return nil
        }
    }

    private func focusDirection(from direction: ghostty_action_goto_split_e) -> NavigationDirection? {
        switch direction {
        // For previous/next, we use left/right as a reasonable default
        // Bonsplit doesn't have cycle-based navigation
        case GHOSTTY_GOTO_SPLIT_PREVIOUS: return .left
        case GHOSTTY_GOTO_SPLIT_NEXT: return .right
        case GHOSTTY_GOTO_SPLIT_UP: return .up
        case GHOSTTY_GOTO_SPLIT_DOWN: return .down
        case GHOSTTY_GOTO_SPLIT_LEFT: return .left
        case GHOSTTY_GOTO_SPLIT_RIGHT: return .right
        default: return nil
        }
    }

    private func resizeDirection(from direction: ghostty_action_resize_split_direction_e) -> ResizeDirection? {
        switch direction {
        case GHOSTTY_RESIZE_SPLIT_UP: return .up
        case GHOSTTY_RESIZE_SPLIT_DOWN: return .down
        case GHOSTTY_RESIZE_SPLIT_LEFT: return .left
        case GHOSTTY_RESIZE_SPLIT_RIGHT: return .right
        default: return nil
        }
    }

    static func callbackContext(from userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceCallbackContext? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttySurfaceCallbackContext>.fromOpaque(userdata).takeUnretainedValue()
    }

    static func runtimeApp(from userdata: UnsafeMutableRawPointer?) -> GhosttyApp? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttyApp>.fromOpaque(userdata).takeUnretainedValue()
    }

    static func registerRuntimeApp(_ runtimeApp: GhosttyApp, for app: ghostty_app_t) {
        let key = UInt(bitPattern: app)
        appRegistryLock.lock()
        appRegistry[key] = runtimeApp
        appRegistryLock.unlock()
    }

    static func setInitializingRuntimeApp(_ runtimeApp: GhosttyApp?) {
        appRegistryLock.lock()
        initializingRuntimeApp = runtimeApp
        appRegistryLock.unlock()
    }

    static func runtimeApp(for app: ghostty_app_t?) -> GhosttyApp? {
        guard let app else { return nil }
        let key = UInt(bitPattern: app)
        appRegistryLock.lock()
        defer { appRegistryLock.unlock() }
        return appRegistry[key]
    }

    static func runtimeAppForActionCallback(_ app: ghostty_app_t?) -> GhosttyApp? {
        appRegistryLock.lock()
        defer { appRegistryLock.unlock() }
        if let app {
            let key = UInt(bitPattern: app)
            if let registered = appRegistry[key] {
                return registered
            }
        }
        return initializingRuntimeApp
    }

    func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        if target.tag != GHOSTTY_TARGET_SURFACE {
            if action.tag == GHOSTTY_ACTION_RELOAD_CONFIG ||
                action.tag == GHOSTTY_ACTION_CONFIG_CHANGE ||
                action.tag == GHOSTTY_ACTION_COLOR_CHANGE {
                logAction(action, target: target, tabId: nil, surfaceId: nil)
            }

            if action.tag == GHOSTTY_ACTION_DESKTOP_NOTIFICATION {
                let actionTitle = action.action.desktop_notification.title
                    .flatMap { String(cString: $0) } ?? ""
                let actionBody = action.action.desktop_notification.body
                    .flatMap { String(cString: $0) } ?? ""
                return performOnMain {
                    guard let tabManager = AppDelegate.shared?.tabManager,
                          let tabId = tabManager.selectedTabId else {
                        return false
                    }
                    let owningManager = AppDelegate.shared?.tabManagerFor(tabId: tabId) ?? tabManager
                    let surfaceId = tabManager.focusedSurfaceId(for: tabId)
                    if let workspace = owningManager.tabs.first(where: { $0.id == tabId }),
                       workspace.suppressesRawTerminalNotification(panelId: surfaceId) {
                        return true
                    }
                    let tabTitle = owningManager.titleForTab(tabId) ?? "Terminal"
                    let command = actionTitle.isEmpty ? tabTitle : actionTitle
                    let body = actionBody
                    TerminalNotificationStore.shared.addNotification(
                        tabId: tabId,
                        surfaceId: surfaceId,
                        title: command,
                        subtitle: "",
                        body: body
                    )
                    return true
                }
            }

            if action.tag == GHOSTTY_ACTION_RING_BELL {
                performOnMain {
                    self.ringBell()
                }
                return true
            }

            if action.tag == GHOSTTY_ACTION_RELOAD_CONFIG {
                let soft = action.action.reload_config.soft
                logThemeAction("reload request target=app soft=\(soft)")
                performOnMain {
                    guard self.shouldProcessGhosttyReloadAction(
                        source: "action.reload_config.app",
                        soft: soft
                    ) else {
                        return
                    }
                    self.reloadConfiguration(soft: soft, source: "action.reload_config.app")
                }
                return true
            }

            if action.tag == GHOSTTY_ACTION_COLOR_CHANGE {
                performOnMain {
                    applyAppColorChange(action.action.color_change, source: "action.color_change.app")
                }
                return true
            }

            if action.tag == GHOSTTY_ACTION_CONFIG_CHANGE {
                // Theme picker preview reloads are resolved through reloadConfiguration.
                // Ghostty's config-change payload can still contain stale app defaults,
                // so it must not own the window chrome appearance.
                synchronizeGhosttyRuntimeColorScheme(
                    effectiveTerminalColorSchemePreference,
                    source: "action.config_change.app:resolved"
                )
                DispatchQueue.main.async {
                    self.applyBackgroundToKeyWindow()
                }
                return true
            }

            return false
        }
        let callbackContext = Self.callbackContext(from: ghostty_surface_userdata(target.target.surface))
        let callbackTabId = callbackContext?.tabId
        let callbackSurfaceId = callbackContext?.surfaceId

        if action.tag == GHOSTTY_ACTION_SHOW_CHILD_EXITED {
            // The child (shell) exited. Ghostty will fall back to printing
            // "Process exited. Press any key..." into the terminal unless the host
            // handles this action. For cmux, the correct behavior is to close
            // the panel immediately (no prompt).
#if DEBUG
            cmuxDebugLog(
                "surface.action.showChildExited tab=\(callbackTabId?.uuidString.prefix(5) ?? "nil") " +
                "surface=\(callbackSurfaceId?.uuidString.prefix(5) ?? "nil")"
            )
#endif
#if DEBUG
            cmuxWriteChildExitProbe(
                [
                    "probeShowChildExitedTabId": callbackTabId?.uuidString ?? "",
                    "probeShowChildExitedSurfaceId": callbackSurfaceId?.uuidString ?? "",
                ],
                increments: ["probeShowChildExitedCount": 1]
            )
#endif
            // Keep host-close async to avoid re-entrant close/deinit while Ghostty is still
            // dispatching this action callback.
            DispatchQueue.main.async {
                guard let app = AppDelegate.shared else { return }
                if let callbackTabId,
                   let callbackSurfaceId,
                   let manager = app.tabManagerFor(tabId: callbackTabId) ?? app.tabManager,
                   let workspace = manager.tabs.first(where: { $0.id == callbackTabId }),
                   workspace.panels[callbackSurfaceId] != nil {
                    manager.closePanelAfterChildExited(tabId: callbackTabId, surfaceId: callbackSurfaceId)
                }
            }
            // Always report handled so Ghostty doesn't print the fallback prompt.
            return true
        }

        guard let surfaceView = callbackContext?.surfaceView else { return false }
        if action.tag == GHOSTTY_ACTION_RELOAD_CONFIG ||
            action.tag == GHOSTTY_ACTION_CONFIG_CHANGE ||
            action.tag == GHOSTTY_ACTION_COLOR_CHANGE {
            logAction(
                action,
                target: target,
                tabId: callbackTabId ?? surfaceView.tabId,
                surfaceId: callbackSurfaceId ?? surfaceView.terminalSurface?.id
            )
        }

        switch action.tag {
        case GHOSTTY_ACTION_NEW_SPLIT:
            guard let tabId = surfaceView.tabId,
                  let surfaceId = surfaceView.terminalSurface?.id,
                  let direction = splitDirection(from: action.action.new_split) else {
                return false
            }
            return performOnMain {
                guard let app = AppDelegate.shared,
                      let tabManager = app.tabManagerFor(tabId: tabId) ?? app.tabManager else {
                    return false
                }
                return tabManager.createSplit(tabId: tabId, surfaceId: surfaceId, direction: direction) != nil
            }
        case GHOSTTY_ACTION_RING_BELL:
            performOnMain {
                self.ringBell()
            }
            return true
        case GHOSTTY_ACTION_GOTO_SPLIT:
            guard let tabId = surfaceView.tabId,
                  surfaceView.terminalSurface != nil,
                  let direction = focusDirection(from: action.action.goto_split) else {
                return false
            }
            return performOnMain {
                guard let tabManager = AppDelegate.shared?.tabManager else { return false }
                return tabManager.moveSplitFocus(tabId: tabId, direction: direction)
            }
        case GHOSTTY_ACTION_RESIZE_SPLIT:
            guard let tabId = surfaceView.tabId,
                  let surfaceId = surfaceView.terminalSurface?.id,
                  let direction = resizeDirection(from: action.action.resize_split.direction) else {
                return false
            }
            let amount = action.action.resize_split.amount
            return performOnMain {
                guard let tabManager = AppDelegate.shared?.tabManager else { return false }
                return tabManager.resizeSplit(
                    tabId: tabId,
                    surfaceId: surfaceId,
                    direction: direction,
                    amount: amount
                )
            }
        case GHOSTTY_ACTION_EQUALIZE_SPLITS:
            guard let tabId = surfaceView.tabId else {
                return false
            }
            return performOnMain {
                guard let tabManager = AppDelegate.shared?.tabManager else { return false }
                return tabManager.equalizeSplits(tabId: tabId)
            }
        case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
            guard let tabId = surfaceView.tabId,
                  let surfaceId = surfaceView.terminalSurface?.id else {
                return false
            }
            return performOnMain {
                guard let tabManager = AppDelegate.shared?.tabManager else { return false }
                return tabManager.toggleSplitZoom(tabId: tabId, surfaceId: surfaceId)
            }
        case GHOSTTY_ACTION_RENDER:
            return false
        case GHOSTTY_ACTION_SCROLLBAR:
            let scrollbar = GhosttyScrollbar(c: action.action.scrollbar)
            surfaceView.enqueueScrollbarUpdate(scrollbar)
            return true
        case GHOSTTY_ACTION_CELL_SIZE:
            let cellSize = CGSize(
                width: CGFloat(action.action.cell_size.width),
                height: CGFloat(action.action.cell_size.height)
            )
            DispatchQueue.main.async {
                surfaceView.cellSize = cellSize
                NotificationCenter.default.post(
                    name: .ghosttyDidUpdateCellSize,
                    object: surfaceView,
                    userInfo: [GhosttyNotificationKey.cellSize: cellSize]
                )
            }
            return true
        case GHOSTTY_ACTION_START_SEARCH:
            guard let terminalSurface = surfaceView.terminalSurface else { return true }
            let needle = action.action.start_search.needle.flatMap { String(cString: $0) }
            DispatchQueue.main.async {
                if let searchState = terminalSurface.searchState {
                    if let needle, !needle.isEmpty {
                        searchState.needle = needle
                    }
                } else {
                    terminalSurface.searchState = TerminalSurface.SearchState(needle: needle ?? "")
                }
                NotificationCenter.default.post(name: .ghosttySearchFocus, object: terminalSurface)
            }
            return true
        case GHOSTTY_ACTION_END_SEARCH:
            guard let terminalSurface = surfaceView.terminalSurface else { return true }
            DispatchQueue.main.async {
                terminalSurface.searchState = nil
            }
            return true
        case GHOSTTY_ACTION_SEARCH_TOTAL:
            guard let terminalSurface = surfaceView.terminalSurface else { return true }
            let rawTotal = action.action.search_total.total
            let total: UInt? = rawTotal >= 0 ? UInt(rawTotal) : nil
            DispatchQueue.main.async {
                terminalSurface.searchState?.total = total
            }
            return true
        case GHOSTTY_ACTION_SEARCH_SELECTED:
            guard let terminalSurface = surfaceView.terminalSurface else { return true }
            let rawSelected = action.action.search_selected.selected
            let selected: UInt? = rawSelected >= 0 ? UInt(rawSelected) : nil
            DispatchQueue.main.async {
                terminalSurface.searchState?.selected = selected
            }
            return true
        case GHOSTTY_ACTION_SET_TITLE:
            let title = action.action.set_title.title
                .flatMap { String(cString: $0) } ?? ""
            if let tabId = surfaceView.tabId,
               let surfaceId = surfaceView.terminalSurface?.id {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .ghosttyDidSetTitle,
                        object: surfaceView,
                        userInfo: [
                            GhosttyNotificationKey.tabId: tabId,
                            GhosttyNotificationKey.surfaceId: surfaceId,
                            GhosttyNotificationKey.title: title,
                        ]
                    )
                }
            }
            return true
        case GHOSTTY_ACTION_PWD:
            guard let tabId = surfaceView.tabId,
                  let surfaceId = surfaceView.terminalSurface?.id else { return true }
            let pwd = action.action.pwd.pwd.flatMap { String(cString: $0) } ?? ""
            DispatchQueue.main.async {
                AppDelegate.shared?.tabManagerFor(tabId: tabId)?.updateSurfaceDirectory(
                    tabId: tabId,
                    surfaceId: surfaceId,
                    directory: pwd
                )
            }
            return true
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            guard let tabId = surfaceView.tabId else { return true }
            let surfaceId = surfaceView.terminalSurface?.id
            let actionTitle = action.action.desktop_notification.title
                .flatMap { String(cString: $0) } ?? ""
            let actionBody = action.action.desktop_notification.body
                .flatMap { String(cString: $0) } ?? ""
            performOnMain {
                let owningManager = AppDelegate.shared?.tabManagerFor(tabId: tabId) ?? AppDelegate.shared?.tabManager
                if let workspace = owningManager?.tabs.first(where: { $0.id == tabId }),
                   workspace.suppressesRawTerminalNotification(panelId: surfaceId) {
                    return
                }
                let tabTitle = owningManager?.titleForTab(tabId) ?? "Terminal"
                let command = actionTitle.isEmpty ? tabTitle : actionTitle
                let body = actionBody
                TerminalNotificationStore.shared.addNotification(
                    tabId: tabId,
                    surfaceId: surfaceId,
                    title: command,
                    subtitle: "",
                    body: body
                )
            }
            return true
        case GHOSTTY_ACTION_COLOR_CHANGE:
            let change = action.action.color_change
            let newColor = color(from: change)
            if action.action.color_change.kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND {
                if backgroundLogEnabled {
                    logBackground(
                        "surface override set tab=\(surfaceView.tabId?.uuidString ?? "nil") surface=\(surfaceView.terminalSurface?.id.uuidString ?? "nil") override=\(newColor.hexString()) default=\(defaultBackgroundColor.hexString()) source=action.color_change.surface"
                    )
                }
                DispatchQueue.main.async { [self] in
                    surfaceView.backgroundColor = newColor
                    surfaceView.applySurfaceBackground()
                    if backgroundLogEnabled {
                        logBackground("OSC background change tab=\(surfaceView.tabId?.uuidString ?? "unknown") color=\(surfaceView.backgroundColor?.description ?? "nil")")
                    }
                    surfaceView.applyWindowBackgroundIfActive()
                }
            } else if backgroundLogEnabled {
                logBackground(
                    "surface color change observed tab=\(surfaceView.tabId?.uuidString ?? "nil") surface=\(surfaceView.terminalSurface?.id.uuidString ?? "nil") kind=\(colorKindLabel(change.kind)) color=\(newColor.hexString()) source=action.color_change.surface"
                )
            }
            return true
        case GHOSTTY_ACTION_CONFIG_CHANGE:
            DispatchQueue.main.async { [self] in
                if let staleOverride = surfaceView.backgroundColor {
                    surfaceView.backgroundColor = nil
                    if backgroundLogEnabled {
                        logBackground(
                            "surface override cleared tab=\(surfaceView.tabId?.uuidString ?? "nil") surface=\(surfaceView.terminalSurface?.id.uuidString ?? "nil") cleared=\(staleOverride.hexString()) source=action.config_change.surface"
                        )
                    }
                    surfaceView.applySurfaceBackground()
                    surfaceView.applyWindowBackgroundIfActive()
                }
            }
            // Keep surface config-change handling scoped to the surface. The app-level
            // default background is owned by reloadConfiguration's resolved GhosttyConfig.
            let effectiveConfigChangeColorScheme = effectiveTerminalColorSchemePreference
            synchronizeGhosttyRuntimeColorScheme(
                effectiveConfigChangeColorScheme,
                source: "action.config_change.surface:resolved"
            )
            DispatchQueue.main.async {
                surfaceView.applySurfaceColorScheme(
                    force: true,
                    preferredColorScheme: effectiveConfigChangeColorScheme
                )
            }
            if backgroundLogEnabled {
                logBackground(
                    "surface config change deferred terminal bg apply tab=\(surfaceView.tabId?.uuidString ?? "nil") surface=\(surfaceView.terminalSurface?.id.uuidString ?? "nil") override=\(surfaceView.backgroundColor?.hexString() ?? "nil") default=\(defaultBackgroundColor.hexString())"
                )
            }
            return true
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            let soft = action.action.reload_config.soft
            let source = "action.reload_config.surface tab=\(surfaceView.tabId?.uuidString ?? "nil") surface=\(surfaceView.terminalSurface?.id.uuidString ?? "nil")"
            logThemeAction(
                "reload request target=surface tab=\(surfaceView.tabId?.uuidString ?? "nil") surface=\(surfaceView.terminalSurface?.id.uuidString ?? "nil") soft=\(soft)"
            )
            return performOnMain {
                guard self.shouldProcessGhosttyReloadAction(source: source, soft: soft) else {
                    return true
                }
                let preferredColorScheme = self.effectiveTerminalColorSchemePreference
                surfaceView.terminalSurface?.hostedView.reapplySurfaceColorSchemeAfterGhosttyConfigReload(
                    preferredColorScheme: preferredColorScheme
                )
                self.reloadSurfaceConfiguration(
                    target.target.surface,
                    soft: soft,
                    source: source,
                    preferredColorScheme: preferredColorScheme
                )
                surfaceView.terminalSurface?.hostedView.refreshHostBackgroundAfterGhosttyConfigReload()
                surfaceView.terminalSurface?.forceRefresh(reason: "surface.reloadConfig")
                return true
            }
        case GHOSTTY_ACTION_KEY_SEQUENCE:
            return performOnMain {
                surfaceView.updateKeySequence(action.action.key_sequence)
                return true
            }
        case GHOSTTY_ACTION_KEY_TABLE:
            return performOnMain {
                surfaceView.updateKeyTable(action.action.key_table)
                return true
            }
        case GHOSTTY_ACTION_OPEN_URL:
            let openUrl = action.action.open_url
            guard let cstr = openUrl.url else { return false }
            let urlString = String(
                data: Data(bytes: cstr, count: Int(openUrl.len)),
                encoding: .utf8
            ) ?? ""
            #if DEBUG
            cmuxDebugLog("link.openURL raw=\(urlString)")
            #endif

            // Try file-path resolution before URL classification.
            // Ghostty's link detection can match file paths that contain
            // slashes or dots (e.g. "docs/spec.md." or "/tmp/spec.md.") as URLs.
            // Attempt to resolve the raw string as a local file first
            // (with trailing-punctuation trimming via cmuxResolveQuicklookPath).
            // If the file exists and cmux can handle it, route through the
            // file viewer instead of the browser.
            let trimmedUrlString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            var normalizedOpenURLString = urlString
            if !trimmedUrlString.isEmpty {
                let filePathResolution: (routed: Bool, fallbackPath: String?) = performOnMain {
                    guard let termSurface = surfaceView.terminalSurface,
                          let workspace = termSurface.owningWorkspace(),
                          !workspace.isRemoteTerminalSurface(termSurface.id) else {
                        return (false, nil)
                    }
                    let cwd = CommandClickFileOpenRouter.resolveWorkingDirectory(
                        workspace: workspace,
                        surfaceId: termSurface.id
                    )
                    guard let resolvedPath = cmuxResolveTerminalOpenURLFilePath(trimmedUrlString, cwd: cwd) else {
                        return (false, nil)
                    }
                    guard CommandClickFileOpenRouter.shouldRouteInCmux(path: resolvedPath) else {
                        return (false, resolvedPath)
                    }
                    #if DEBUG
                    cmuxDebugLog("link.openURL resolvedAsFilePath=\(resolvedPath)")
                    #endif
                    let fileURL = URL(fileURLWithPath: resolvedPath)
                    CommandClickFileOpenRouter.deferredOpenFileInCmux(
                        workspace: workspace,
                        preferredWorkspaceId: workspace.id,
                        surfaceId: termSurface.id,
                        filePath: resolvedPath
                    ) {
                        NSWorkspace.shared.open(fileURL)
                    }
                    return (true, resolvedPath)
                }
                if let fallbackPath = filePathResolution.fallbackPath {
                    normalizedOpenURLString = fallbackPath
                }
                if filePathResolution.routed {
                    return true
                }
            }

            guard let target = resolveTerminalOpenURLTarget(normalizedOpenURLString) else {
                #if DEBUG
                cmuxDebugLog("link.openURL resolve failed, returning false")
                #endif
                return false
            }
            // Route local file URLs into cmux when the file-routing toggle is on.
            // URL fragments/queries are stripped (the panel only needs the file
            // path), so links emitted by tools like Claude Code (`foo.md#L42`)
            // still route into the viewer. Anything else (toggle off, hosted
            // file URL, remote workspace, unreadable file, split creation
            // failure) falls through to the existing NSWorkspace path below so
            // URL semantics are preserved.
            let fileURLHost = target.url.host
            if target.url.isFileURL,
               fileURLHost == nil || fileURLHost?.isEmpty == true || fileURLHost == "localhost" {
                let fileURL = target.url
                let routed: Bool = performOnMain {
                    guard let termSurface = surfaceView.terminalSurface,
                          let workspace = termSurface.owningWorkspace(),
                          !workspace.isRemoteTerminalSurface(termSurface.id),
                          CommandClickFileOpenRouter.shouldRouteInCmux(path: fileURL.path) else {
                        return false
                    }
                    CommandClickFileOpenRouter.deferredOpenFileInCmux(
                        workspace: workspace,
                        preferredWorkspaceId: workspace.id,
                        surfaceId: termSurface.id,
                        filePath: fileURL.path
                    ) {
                        NSWorkspace.shared.open(fileURL)
                    }
                    return true
                }
                if routed {
                    return true
                }
                // Fall through to the existing NSWorkspace path below.
            }

            if !BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowser() {
                #if DEBUG
                cmuxDebugLog("link.openURL cmuxBrowser=disabled, opening externally url=\(target.url)")
                #endif
                return performOnMain {
                    NSWorkspace.shared.open(target.url)
                }
            }
            switch target {
            case let .external(url):
                #if DEBUG
                cmuxDebugLog("link.openURL target=external, opening externally url=\(url)")
                #endif
                return performOnMain {
                    NSWorkspace.shared.open(url)
                }
            case let .embeddedBrowser(url):
                if BrowserLinkOpenSettings.shouldOpenExternally(url) {
                    #if DEBUG
                    cmuxDebugLog("link.openURL target=embedded but shouldOpenExternally=true url=\(url)")
                    #endif
                    return performOnMain {
                        NSWorkspace.shared.open(url)
                    }
                }
                guard let host = BrowserInsecureHTTPSettings.normalizeHost(url.host ?? "") else {
                    #if DEBUG
                    cmuxDebugLog("link.openURL target=embedded but normalizeHost=nil host=\(url.host ?? "nil") url=\(url)")
                    #endif
                    return performOnMain {
                        NSWorkspace.shared.open(url)
                    }
                }

                // If a host whitelist is configured and this host isn't in it, open externally.
                if !BrowserLinkOpenSettings.hostMatchesWhitelist(host) {
                    #if DEBUG
                    cmuxDebugLog("link.openURL target=embedded but hostWhitelist miss host=\(host) url=\(url)")
                    #endif
                    return performOnMain {
                        NSWorkspace.shared.open(url)
                    }
                }
                let sourceWorkspaceId = callbackTabId ?? surfaceView.tabId
                let sourcePanelId = callbackSurfaceId ?? surfaceView.terminalSurface?.id
                guard let sourceWorkspaceId,
                      let sourcePanelId else {
                    #if DEBUG
                    cmuxDebugLog("link.openURL target=embedded but tabId/surfaceId=nil")
                    #endif
                    return false
                }
                #if DEBUG
                cmuxDebugLog(
                    "link.openURL target=embedded, opening in browser pane " +
                    "host=\(host) url=\(url) tabId=\(sourceWorkspaceId) surfaceId=\(sourcePanelId)"
                )
                #endif
                let canAttemptEmbeddedOpen = performOnMain {
                    BrowserAvailabilitySettings.isEnabled() &&
                    AppDelegate.shared?.workspaceContainingPanel(
                        panelId: sourcePanelId,
                        preferredWorkspaceId: sourceWorkspaceId
                    ) != nil
                }
                guard canAttemptEmbeddedOpen else {
                    #if DEBUG
                    cmuxDebugLog(
                        "link.openURL embedded preflight failed, opening externally " +
                        "tabId=\(sourceWorkspaceId) surfaceId=\(sourcePanelId) url=\(url)"
                    )
                    #endif
                    return performOnMain {
                        NSWorkspace.shared.open(url)
                    }
                }

                // Browser split creation changes focus, which unfocuses the source terminal and
                // calls back into Ghostty. Defer that work until this open_url callback returns.
                // From here cmux owns the open attempt and the deferred path falls back externally.
                Task { @MainActor [url, sourceWorkspaceId, sourcePanelId, host] in
                    let didOpen = Self.openEmbeddedBrowserLink(
                        url: url,
                        sourceWorkspaceId: sourceWorkspaceId,
                        sourcePanelId: sourcePanelId,
                        host: host
                    )
                    guard didOpen else {
                        #if DEBUG
                        cmuxDebugLog("link.openURL deferred open failed url=\(url)")
                        #endif
                        NSSound.beep()
                        return
                    }
                }
                return true
            }
        default:
            return false
        }
    }

}
