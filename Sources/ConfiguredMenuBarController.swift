import AppKit
import Foundation

struct ConfiguredMenuBarRuntimeContext {
    var menus: [CmuxResolvedMenuBarMenu]
    var extensions: [CmuxResolvedMenuBarExtension]
    var configStore: CmuxConfigStore?
    var workingDirectory: String
}

private enum ConfiguredMenuBarDynamicPhase: String, Sendable {
    case idle
    case running
    case loaded
    case failed
}

private struct ConfiguredMenuBarDynamicState: Sendable {
    var phase: ConfiguredMenuBarDynamicPhase = .idle
    var items: [CmuxResolvedMenuBarItem] = []
    var error: String?
    var lastRunAt: Date?
    var durationMS: Int?
    var exitStatus: Int32?
    var activePID: Int32?
    var activeRunID: UUID?
    var generatedItemCount: Int?
    var command: String?
    var lastConfigRevisionRun: UInt64?
}

private struct ConfiguredMenuBarDynamicCommandResult: Sendable {
    var stdout: String
    var stderr: String
    var exitStatus: Int32?
    var durationMS: Int
    var errorMessage: String?
}

private final class ConfiguredMenuBarOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var exceededLimit = false

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if data.count + chunk.count > limit {
            exceededLimit = true
            let remaining = max(0, limit - data.count)
            if remaining > 0 {
                data.append(chunk.prefix(remaining))
            }
            return
        }
        data.append(chunk)
    }

    func string() -> String {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return String(data: snapshot, encoding: .utf8)
            ?? String(decoding: snapshot, as: UTF8.self)
    }

    func didExceedLimit() -> Bool {
        lock.lock()
        let exceeded = exceededLimit
        lock.unlock()
        return exceeded
    }
}

private enum ConfiguredMenuBarDynamicRunner {
    static let defaultTimeoutSeconds: Double = 5
    static let outputLimitBytes = 256 * 1024

    static func run(
        command: String,
        cwd: String,
        timeoutSeconds: Double,
        onStarted: @escaping (Int32) -> Void
    ) async -> ConfiguredMenuBarDynamicCommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                runBlocking(
                    command: command,
                    cwd: cwd,
                    timeoutSeconds: timeoutSeconds,
                    onStarted: onStarted,
                    continuation: continuation
                )
            }
        }
    }

    private static func runBlocking(
        command: String,
        cwd: String,
        timeoutSeconds: Double,
        onStarted: @escaping (Int32) -> Void,
        continuation: CheckedContinuation<ConfiguredMenuBarDynamicCommandResult, Never>
    ) {
        let startedAt = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdout = ConfiguredMenuBarOutputCollector(limit: outputLimitBytes)
        let stderr = ConfiguredMenuBarOutputCollector(limit: outputLimitBytes)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            stdout.append(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            stderr.append(handle.availableData)
        }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let finishLock = NSLock()
        var didFinish = false
        var didTimeOut = false
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))

        func finish(_ result: ConfiguredMenuBarDynamicCommandResult) {
            finishLock.lock()
            guard !didFinish else {
                finishLock.unlock()
                return
            }
            didFinish = true
            finishLock.unlock()
            timer.cancel()
            continuation.resume(returning: result)
        }

        process.terminationHandler = { terminatedProcess in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            stdout.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            stderr.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            let durationMS = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
            finishLock.lock()
            let timedOut = didTimeOut
            finishLock.unlock()

            let stdoutText = stdout.string()
            let stderrText = stderr.string()
            let errorMessage: String?
            if timedOut {
                errorMessage = String(
                    format: String(
                        localized: "menuBar.dynamic.error.timeout",
                        defaultValue: "Command timed out after %.1f seconds."
                    ),
                    timeoutSeconds
                )
            } else if stdout.didExceedLimit() || stderr.didExceedLimit() {
                errorMessage = String(
                    format: String(
                        localized: "menuBar.dynamic.error.outputLimit",
                        defaultValue: "Command output exceeded %d bytes."
                    ),
                    outputLimitBytes
                )
            } else if terminatedProcess.terminationStatus != 0 {
                let detail = stderrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
                    : stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
                errorMessage = [
                    String(
                        format: String(
                            localized: "menuBar.dynamic.error.exitStatus",
                            defaultValue: "Command exited with status %d."
                        ),
                        Int(terminatedProcess.terminationStatus)
                    ),
                    detail
                ].filter { !$0.isEmpty }.joined(separator: "\n")
            } else {
                errorMessage = nil
            }

            finish(ConfiguredMenuBarDynamicCommandResult(
                stdout: stdoutText,
                stderr: stderrText,
                exitStatus: terminatedProcess.terminationStatus,
                durationMS: durationMS,
                errorMessage: errorMessage
            ))
        }

        do {
            try process.run()
            onStarted(process.processIdentifier)
        } catch {
            let durationMS = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            finish(ConfiguredMenuBarDynamicCommandResult(
                stdout: "",
                stderr: "",
                exitStatus: nil,
                durationMS: durationMS,
                errorMessage: error.localizedDescription
            ))
            return
        }

        timer.schedule(deadline: .now() + max(0.1, timeoutSeconds))
        timer.setEventHandler {
            finishLock.lock()
            guard !didFinish else {
                finishLock.unlock()
                return
            }
            didTimeOut = true
            finishLock.unlock()
            process.terminate()
        }
        timer.resume()
    }
}

@MainActor
final class ConfiguredMenuBarController: NSObject {
    private final class ActionBox: NSObject {
        let action: CmuxResolvedConfigAction

        init(action: CmuxResolvedConfigAction) {
            self.action = action
        }
    }

    private final class DynamicSourceBox: NSObject {
        let sourceID: String

        init(sourceID: String) {
            self.sourceID = sourceID
        }
    }

    private final class DynamicErrorBox: NSObject {
        let error: String

        init(error: String) {
            self.error = error
        }
    }

    private final class DynamicMenuDelegate: NSObject, NSMenuDelegate {
        weak var owner: ConfiguredMenuBarController?
        let sourceID: String
        weak var preferredWindow: NSWindow?

        init(owner: ConfiguredMenuBarController, sourceID: String, preferredWindow: NSWindow?) {
            self.owner = owner
            self.sourceID = sourceID
            self.preferredWindow = preferredWindow
        }

        func menuWillOpen(_ menu: NSMenu) {
            owner?.dynamicMenuWillOpen(sourceID: sourceID, preferredWindow: preferredWindow)
        }
    }

    private enum DynamicRefreshReason {
        case open
        case manual
        case configReload
        case interval
    }

    private weak var owner: AppDelegate?
    private let notificationCenter: NotificationCenter
    private var observerTokens: [NSObjectProtocol] = []
    private var topLevelItems: [NSMenuItem] = []
    private var extensionItems: [NSMenuItem] = []
    private var actionBoxes: [ActionBox] = []
    private var dynamicSourceBoxes: [DynamicSourceBox] = []
    private var dynamicErrorBoxes: [DynamicErrorBox] = []
    private var menuDelegates: [DynamicMenuDelegate] = []
    private var dynamicStates: [String: ConfiguredMenuBarDynamicState] = [:]
    private var dynamicSourceByID: [String: CmuxResolvedMenuBarDynamicSource] = [:]
    private var dynamicMenus: [String: NSMenu] = [:]
    private var dynamicTimers: [String: DispatchSourceTimer] = [:]
    private var dynamicTimerKeys: [String: String] = [:]
    private var dynamicTasks: [String: Task<Void, Never>] = [:]
    private var refreshScheduled = false

    init(owner: AppDelegate, notificationCenter: NotificationCenter = .default) {
        self.owner = owner
        self.notificationCenter = notificationCenter
        super.init()
    }

    deinit {
        for token in observerTokens {
            notificationCenter.removeObserver(token)
        }
        for timer in dynamicTimers.values {
            timer.cancel()
        }
        for task in dynamicTasks.values {
            task.cancel()
        }
    }

    func installObserversIfNeeded() {
        guard observerTokens.isEmpty else { return }
        let names: [Notification.Name] = [
            .cmuxConfigStoreDidChange,
            .mainWindowContextsDidChange,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
        ]
        observerTokens = names.map { name in
            notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scheduleRefresh()
                }
            }
        }
        scheduleRefresh()
    }

    func taskManagerPayload() -> [[String: Any]] {
        dynamicSourceByID.values
            .sorted { lhs, rhs in
                if lhs.title == rhs.title { return lhs.id < rhs.id }
                return lhs.title < rhs.title
            }
            .map { source in
                let state = dynamicStates[source.id] ?? ConfiguredMenuBarDynamicState()
                var detailParts: [String] = [phaseLabel(state.phase)]
                if let generatedItemCount = state.generatedItemCount {
                    detailParts.append(String(
                        format: String(
                            localized: "taskManager.dynamicMenu.items",
                            defaultValue: "%d items"
                        ),
                        generatedItemCount
                    ))
                }
                if let durationMS = state.durationMS {
                    detailParts.append(String(
                        format: String(
                            localized: "taskManager.dynamicMenu.duration",
                            defaultValue: "%d ms"
                        ),
                        durationMS
                    ))
                }
                let pids = state.activePID.map { [Int($0)] } ?? []
                return [
                    "id": source.id,
                    "title": source.title,
                    "detail": detailParts.joined(separator: " / "),
                    "state": state.phase.rawValue,
                    "active_pid": state.activePID.map { Int($0) } as Any? ?? NSNull(),
                    "root_pids": pids,
                    "pids": pids,
                    "source_path": source.settingSourcePath as Any? ?? NSNull(),
                    "resources": CmuxTaskManagerResources.zeroPayload
                ]
            }
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshScheduled = false
                self.refresh()
            }
        }
    }

    private func refresh() {
        guard let mainMenu = NSApp.mainMenu else { return }

        removeConfiguredItems(from: mainMenu)

        let preferredWindow = NSApp.keyWindow ?? NSApp.mainWindow
        let runtime = owner?.configuredMenuBarRuntimeContext(preferredWindow: preferredWindow)
        let menus = runtime?.menus ?? []
        let extensions = runtime?.extensions ?? []
        guard !menus.isEmpty || !extensions.isEmpty else {
            resetDynamicSources()
            return
        }

        var insertionIndex = insertionIndex(in: mainMenu)
        var customMenusByConfigID: [String: NSMenu] = [:]
        for menu in menus {
            let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            let submenu = configuredMenu(from: menu, preferredWindow: preferredWindow)
            item.submenu = submenu
            mainMenu.insertItem(item, at: insertionIndex)
            topLevelItems.append(item)
            customMenusByConfigID[menu.configID] = submenu
            insertionIndex += 1
        }

        for menuExtension in extensions {
            guard let targetMenu = targetMenu(
                for: menuExtension.targetID,
                mainMenu: mainMenu,
                customMenusByConfigID: customMenusByConfigID
            ) else {
                continue
            }
            let items = menuItems(from: menuExtension.items, preferredWindow: preferredWindow)
            guard !items.isEmpty else { continue }
            if !targetMenu.items.isEmpty, items.first?.isSeparatorItem == false {
                let separator = NSMenuItem.separator()
                targetMenu.addItem(separator)
                extensionItems.append(separator)
            }
            for item in items {
                targetMenu.addItem(item)
                extensionItems.append(item)
            }
        }

        dynamicStates = dynamicStates.filter {
            dynamicSourceByID[$0.key] != nil
        }
        cancelRemovedDynamicTimers()
        cancelRemovedDynamicTasks()
        scheduleIntervalDynamicSourcesIfNeeded(store: runtime?.configStore, preferredWindow: preferredWindow)
        runConfigReloadDynamicSourcesIfNeeded(store: runtime?.configStore, preferredWindow: preferredWindow)
    }

    private func removeConfiguredItems(from mainMenu: NSMenu) {
        for item in extensionItems {
            let menu = item.menu
            let index = menu?.index(of: item) ?? -1
            if let menu, index >= 0 {
                menu.removeItem(at: index)
            }
        }
        extensionItems.removeAll()

        for item in topLevelItems {
            let index = mainMenu.index(of: item)
            if index >= 0 {
                mainMenu.removeItem(at: index)
            }
        }
        topLevelItems.removeAll()
        actionBoxes.removeAll()
        dynamicSourceBoxes.removeAll()
        dynamicErrorBoxes.removeAll()
        menuDelegates.removeAll()
        dynamicSourceByID.removeAll()
        dynamicMenus.removeAll()
    }

    private func resetDynamicSources() {
        dynamicStates.removeAll()
        for sourceID in Array(dynamicTimers.keys) {
            cancelDynamicTimer(sourceID: sourceID)
        }
        for sourceID in Array(dynamicTasks.keys) {
            cancelDynamicTask(sourceID: sourceID)
        }
    }

    private func insertionIndex(in mainMenu: NSMenu) -> Int {
        let notificationsTitle = String(localized: "menu.notifications.title", defaultValue: "Notifications")
        if let notificationsIndex = mainMenu.items.lastIndex(where: { $0.title == notificationsTitle }) {
            return notificationsIndex + 1
        }
#if DEBUG
        if let debugIndex = mainMenu.items.lastIndex(where: { $0.title == "Debug" }) {
            return debugIndex
        }
#endif
        return min(mainMenu.items.count, max(1, mainMenu.items.count - 1))
    }

    private func configuredMenu(
        from menu: CmuxResolvedMenuBarMenu,
        preferredWindow: NSWindow?
    ) -> NSMenu {
        let nsMenu = NSMenu(title: menu.title)
        for item in menuItems(from: menu.items, preferredWindow: preferredWindow) {
            nsMenu.addItem(item)
        }
        return nsMenu
    }

    private func menuItems(
        from items: [CmuxResolvedMenuBarItem],
        preferredWindow: NSWindow?
    ) -> [NSMenuItem] {
        var nsItems: [NSMenuItem] = []
        for item in items {
            switch item {
            case .separator:
                if !nsItems.isEmpty, nsItems.last?.isSeparatorItem == false {
                    nsItems.append(.separator())
                }
            case .submenu(let submenu):
                let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
                item.submenu = configuredMenu(from: submenu, preferredWindow: preferredWindow)
                nsItems.append(item)
            case .dynamicSource(let source):
                nsItems.append(dynamicSourceMenuItem(for: source, preferredWindow: preferredWindow))
            case .action(let menuAction):
                let item = NSMenuItem(
                    title: menuAction.title,
                    action: #selector(performMenuItem(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                let box = ActionBox(action: menuAction.action)
                actionBoxes.append(box)
                item.representedObject = box
                item.toolTip = menuAction.tooltip
                item.image = menuImage(for: menuAction.icon ?? menuAction.action.icon)
                nsItems.append(item)
            }
        }

        while nsItems.last?.isSeparatorItem == true {
            nsItems.removeLast()
        }
        return nsItems
    }

    private func menuImage(for icon: CmuxButtonIcon?) -> NSImage? {
        guard case .some(.symbol(let symbolName)) = icon else { return nil }
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    }

    private func dynamicSourceMenuItem(
        for source: CmuxResolvedMenuBarDynamicSource,
        preferredWindow: NSWindow?
    ) -> NSMenuItem {
        var state = dynamicStates[source.id] ?? ConfiguredMenuBarDynamicState()
        if state.command != nil, state.command != source.source.command {
            state = ConfiguredMenuBarDynamicState()
            cancelDynamicTimer(sourceID: source.id)
            cancelDynamicTask(sourceID: source.id)
        }
        state.command = source.source.command
        dynamicStates[source.id] = state
        dynamicSourceByID[source.id] = source

        let item = NSMenuItem(title: source.title, action: nil, keyEquivalent: "")
        item.image = menuImage(for: source.icon)
        item.toolTip = source.tooltip
        let submenu = NSMenu(title: source.title)
        let delegate = DynamicMenuDelegate(owner: self, sourceID: source.id, preferredWindow: preferredWindow)
        submenu.delegate = delegate
        menuDelegates.append(delegate)
        dynamicMenus[source.id] = submenu
        item.submenu = submenu
        renderDynamicSourceMenu(sourceID: source.id, preferredWindow: preferredWindow)
        return item
    }

    private func targetMenu(
        for targetID: String,
        mainMenu: NSMenu,
        customMenusByConfigID: [String: NSMenu]
    ) -> NSMenu? {
        if let customMenu = customMenusByConfigID[targetID] {
            return customMenu
        }
        let normalized = normalizedTargetID(targetID)
        if let customMenu = customMenusByConfigID.first(where: {
            normalizedTargetID($0.key) == normalized
        })?.value {
            return customMenu
        }

        let builtinTitles: [String: String] = [
            "application": "",
            "app": "",
            "cmux": "",
            "file": String(localized: "menu.file.title", defaultValue: "File"),
            "edit": String(localized: "menu.edit.title", defaultValue: "Edit"),
            "view": String(localized: "menu.view.title", defaultValue: "View"),
            "notifications": String(localized: "menu.notifications.title", defaultValue: "Notifications"),
            "window": String(localized: "menu.window.title", defaultValue: "Window"),
            "help": String(localized: "menu.help.title", defaultValue: "Help"),
        ]
        if ["application", "app", "cmux"].contains(normalized) {
            return mainMenu.items.first?.submenu
        }
        guard let title = builtinTitles[normalized] else { return nil }
        return mainMenu.items.first(where: { $0.title == title })?.submenu
    }

    private func normalizedTargetID(_ raw: String) -> String {
        raw.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func runConfigReloadDynamicSourcesIfNeeded(store: CmuxConfigStore?, preferredWindow: NSWindow?) {
        guard let store else { return }
        for source in dynamicSourceByID.values {
            guard source.source.refresh == .onConfigReload else { continue }
            let lastRevision = dynamicStates[source.id]?.lastConfigRevisionRun
            guard lastRevision != store.configRevision else { continue }
            dynamicStates[source.id, default: ConfiguredMenuBarDynamicState()].lastConfigRevisionRun = store.configRevision
            refreshDynamicSource(sourceID: source.id, preferredWindow: preferredWindow, reason: .configReload)
        }
    }

    private func scheduleIntervalDynamicSourcesIfNeeded(store: CmuxConfigStore?, preferredWindow: NSWindow?) {
        guard let store else { return }
        for source in dynamicSourceByID.values {
            guard source.source.refresh == .interval,
                  let interval = source.source.intervalSeconds else {
                cancelDynamicTimer(sourceID: source.id)
                continue
            }
            let timerKey = [
                source.source.command,
                String(interval),
                source.settingSourcePath ?? "",
            ].joined(separator: "\u{1F}")
            guard dynamicTimerKeys[source.id] != timerKey else { continue }
            cancelDynamicTimer(sourceID: source.id)

            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + interval, repeating: interval)
            timer.setEventHandler { [weak self, weak store] in
                MainActor.assumeIsolated {
                    guard let self, let store else { return }
                    guard let currentSource = self.dynamicSourceByID[source.id] else {
                        self.cancelDynamicTimer(sourceID: source.id)
                        return
                    }
                    guard CmuxConfigExecutor.isTrustedDynamicMenuSource(
                        command: currentSource.source.command,
                        sourceID: currentSource.id,
                        configSourcePath: currentSource.settingSourcePath,
                        globalConfigPath: store.globalConfigPath
                    ) else {
                        return
                    }
                    self.refreshDynamicSource(
                        sourceID: currentSource.id,
                        preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow,
                        reason: .interval
                    )
                }
            }
            dynamicTimers[source.id] = timer
            dynamicTimerKeys[source.id] = timerKey
            timer.resume()
        }
    }

    private func cancelRemovedDynamicTimers() {
        let activeSourceIDs = Set(dynamicSourceByID.keys)
        for sourceID in Array(dynamicTimers.keys) where !activeSourceIDs.contains(sourceID) {
            cancelDynamicTimer(sourceID: sourceID)
        }
    }

    private func cancelRemovedDynamicTasks() {
        let activeSourceIDs = Set(dynamicSourceByID.keys)
        for sourceID in Array(dynamicTasks.keys) where !activeSourceIDs.contains(sourceID) {
            cancelDynamicTask(sourceID: sourceID)
        }
    }

    private func cancelDynamicTimer(sourceID: String) {
        dynamicTimers[sourceID]?.cancel()
        dynamicTimers.removeValue(forKey: sourceID)
        dynamicTimerKeys.removeValue(forKey: sourceID)
    }

    private func cancelDynamicTask(sourceID: String) {
        dynamicTasks[sourceID]?.cancel()
        dynamicTasks.removeValue(forKey: sourceID)
        dynamicStates[sourceID]?.activeRunID = nil
        dynamicStates[sourceID]?.activePID = nil
    }

    private func dynamicMenuWillOpen(sourceID: String, preferredWindow: NSWindow?) {
        guard let source = dynamicSourceByID[sourceID] else { return }
        renderDynamicSourceMenu(sourceID: sourceID, preferredWindow: preferredWindow)
        if (source.source.refresh ?? .onOpen) == .onOpen {
            refreshDynamicSource(sourceID: sourceID, preferredWindow: preferredWindow, reason: .open)
        }
    }

    private func renderDynamicSourceMenu(sourceID: String, preferredWindow: NSWindow?) {
        guard let menu = dynamicMenus[sourceID],
              let source = dynamicSourceByID[sourceID] else { return }
        let state = dynamicStates[sourceID] ?? ConfiguredMenuBarDynamicState()
        menu.removeAllItems()

        let cachedItems = menuItems(from: state.items, preferredWindow: preferredWindow)
        for item in cachedItems {
            menu.addItem(item)
        }
        if cachedItems.isEmpty {
            menu.addItem(disabledItem(title: dynamicMenuEmptyTitle(for: state)))
        }

        if state.phase == .running {
            addSeparatorIfNeeded(to: menu)
            menu.addItem(disabledItem(title: String(
                localized: "menuBar.dynamic.running",
                defaultValue: "Loading..."
            )))
        }

        if let error = state.error, !error.isEmpty {
            addSeparatorIfNeeded(to: menu)
            menu.addItem(disabledItem(title: String(
                localized: "menuBar.dynamic.failed",
                defaultValue: "Dynamic menu failed"
            )))
            let copyItem = NSMenuItem(
                title: String(localized: "menuBar.dynamic.copyError", defaultValue: "Copy Error"),
                action: #selector(copyDynamicSourceError(_:)),
                keyEquivalent: ""
            )
            copyItem.target = self
            let box = DynamicErrorBox(error: error)
            dynamicErrorBoxes.append(box)
            copyItem.representedObject = box
            menu.addItem(copyItem)
        }

        addSeparatorIfNeeded(to: menu)
        let reloadTitle = state.phase == .idle && (source.source.refresh ?? .onOpen) == .manual
            ? String(localized: "menuBar.dynamic.load", defaultValue: "Load Dynamic Menu")
            : String(localized: "menuBar.dynamic.reload", defaultValue: "Reload")
        let reloadItem = NSMenuItem(
            title: reloadTitle,
            action: #selector(reloadDynamicSource(_:)),
            keyEquivalent: ""
        )
        reloadItem.target = self
        reloadItem.isEnabled = state.phase != .running
        let box = DynamicSourceBox(sourceID: sourceID)
        dynamicSourceBoxes.append(box)
        reloadItem.representedObject = box
        menu.addItem(reloadItem)
    }

    private func disabledItem(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func dynamicMenuEmptyTitle(for state: ConfiguredMenuBarDynamicState) -> String {
        switch state.phase {
        case .running:
            return String(localized: "menuBar.dynamic.loading", defaultValue: "Loading...")
        case .failed where state.items.isEmpty:
            return String(localized: "menuBar.dynamic.noCachedItems", defaultValue: "No cached items")
        case .loaded:
            return String(localized: "menuBar.dynamic.noItems", defaultValue: "No items")
        case .idle, .failed:
            return String(localized: "menuBar.dynamic.notLoaded", defaultValue: "Not loaded")
        }
    }

    private func addSeparatorIfNeeded(to menu: NSMenu) {
        if !menu.items.isEmpty, menu.items.last?.isSeparatorItem == false {
            menu.addItem(.separator())
        }
    }

    private func refreshDynamicSource(
        sourceID: String,
        preferredWindow: NSWindow?,
        reason: DynamicRefreshReason
    ) {
        guard let source = dynamicSourceByID[sourceID] else { return }
        guard dynamicStates[sourceID]?.phase != .running else { return }
        guard let store = owner?.configuredMenuBarRuntimeContext(preferredWindow: preferredWindow).configStore else { return }

        let title = String(
            format: String(
                localized: "dialog.cmuxConfig.confirmDynamicMenu.title",
                defaultValue: "Run Dynamic Menu Source: %@"
            ),
            source.title
        )
        let authorized = CmuxConfigExecutor.authorizeDynamicMenuSourceIfNeeded(
            command: source.source.command,
            sourceID: source.id,
            configSourcePath: source.settingSourcePath,
            globalConfigPath: store.globalConfigPath,
            displayTitle: title,
            presentingWindow: preferredWindow
        ) { [weak self, weak store, weak preferredWindow] command in
            guard let self, let store else { return }
            self.startDynamicSource(
                source,
                command: command,
                store: store,
                preferredWindow: preferredWindow,
                reason: reason
            )
        }
        if !authorized {
            var state = dynamicStates[sourceID] ?? ConfiguredMenuBarDynamicState()
            state.phase = state.items.isEmpty ? .idle : .loaded
            dynamicStates[sourceID] = state
            renderDynamicSourceMenu(sourceID: sourceID, preferredWindow: preferredWindow)
        }
    }

    private func startDynamicSource(
        _ source: CmuxResolvedMenuBarDynamicSource,
        command: String,
        store: CmuxConfigStore,
        preferredWindow: NSWindow?,
        reason: DynamicRefreshReason
    ) {
        let runID = UUID()
        var state = dynamicStates[source.id] ?? ConfiguredMenuBarDynamicState()
        state.phase = .running
        state.error = nil
        state.command = command
        state.lastRunAt = Date()
        state.activeRunID = runID
        state.activePID = nil
        dynamicStates[source.id] = state
        renderDynamicSourceMenu(sourceID: source.id, preferredWindow: preferredWindow)

        let runtime = owner?.configuredMenuBarRuntimeContext(preferredWindow: preferredWindow)
        let workingDirectory = runtime?.workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
        let timeout = source.source.timeoutSeconds ?? ConfiguredMenuBarDynamicRunner.defaultTimeoutSeconds

        cancelDynamicTask(sourceID: source.id)
        dynamicStates[source.id, default: ConfiguredMenuBarDynamicState()].activeRunID = runID
        dynamicStates[source.id, default: ConfiguredMenuBarDynamicState()].phase = .running

        dynamicTasks[source.id] = Task { @MainActor [weak self, weak store, weak preferredWindow] in
            let sourceID = source.id
            let result = await ConfiguredMenuBarDynamicRunner.run(
                command: command,
                cwd: workingDirectory,
                timeoutSeconds: timeout
            ) { [weak self, sourceID, runID, weak preferredWindow] pid in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        guard self.dynamicStates[sourceID]?.activeRunID == runID else { return }
                        self.dynamicStates[sourceID, default: ConfiguredMenuBarDynamicState()].activePID = pid
                        self.renderDynamicSourceMenu(sourceID: sourceID, preferredWindow: preferredWindow)
                    }
                }
            }
            guard !Task.isCancelled else { return }
            guard let self, let store else { return }
            guard self.dynamicStates[sourceID]?.activeRunID == runID else { return }
            self.finishDynamicSource(
                source,
                runID: runID,
                result: result,
                store: store,
                preferredWindow: preferredWindow
            )
            self.dynamicTasks.removeValue(forKey: sourceID)
        }
    }

    private func finishDynamicSource(
        _ source: CmuxResolvedMenuBarDynamicSource,
        runID: UUID,
        result: ConfiguredMenuBarDynamicCommandResult,
        store: CmuxConfigStore,
        preferredWindow: NSWindow?
    ) {
        guard dynamicStates[source.id]?.activeRunID == runID else { return }
        var state = dynamicStates[source.id] ?? ConfiguredMenuBarDynamicState()
        state.activeRunID = nil
        state.activePID = nil
        state.durationMS = result.durationMS
        state.exitStatus = result.exitStatus

        if let error = result.errorMessage {
            state.phase = .failed
            state.error = error
            dynamicStates[source.id] = state
            renderDynamicSourceMenu(sourceID: source.id, preferredWindow: preferredWindow)
            owner?.notifyConfiguredMenuBarDynamicFailure(source: source, error: error, preferredWindow: preferredWindow)
            return
        }

        do {
            let data = Data(result.stdout.utf8)
            let generatedItems = try JSONDecoder().decode([CmuxConfigMenuBarItem].self, from: data)
            let resolved = store.resolveGeneratedMenuBarItems(
                generatedItems,
                settingName: "\(source.settingName).generated",
                settingSourcePath: source.settingSourcePath
            )
            if let issue = resolved.issues.first {
                throw NSError(domain: "CmuxDynamicMenu", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: issue.logMessage
                ])
            }
            state.phase = .loaded
            state.items = resolved.items
            state.error = nil
            state.generatedItemCount = resolved.items.count
        } catch {
            state.phase = .failed
            state.error = error.localizedDescription
            owner?.notifyConfiguredMenuBarDynamicFailure(
                source: source,
                error: error.localizedDescription,
                preferredWindow: preferredWindow
            )
        }
        dynamicStates[source.id] = state
        renderDynamicSourceMenu(sourceID: source.id, preferredWindow: preferredWindow)
    }

    private func phaseLabel(_ phase: ConfiguredMenuBarDynamicPhase) -> String {
        switch phase {
        case .idle:
            return String(localized: "taskManager.dynamicMenu.idle", defaultValue: "Idle")
        case .running:
            return String(localized: "taskManager.dynamicMenu.running", defaultValue: "Running")
        case .loaded:
            return String(localized: "taskManager.dynamicMenu.loaded", defaultValue: "Loaded")
        case .failed:
            return String(localized: "taskManager.dynamicMenu.failed", defaultValue: "Failed")
        }
    }

    @objc private func performMenuItem(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ActionBox else {
            NSSound.beep()
            return
        }
        guard owner?.performConfiguredMenuBarAction(box.action, preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow) == true else {
            NSSound.beep()
            return
        }
    }

    @objc private func reloadDynamicSource(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? DynamicSourceBox else {
            NSSound.beep()
            return
        }
        refreshDynamicSource(
            sourceID: box.sourceID,
            preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow,
            reason: .manual
        )
    }

    @objc private func copyDynamicSourceError(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? DynamicErrorBox else {
            NSSound.beep()
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(box.error, forType: .string)
    }
}
