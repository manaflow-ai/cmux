import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers
import os


// MARK: - Submit Event Runner
private extension TerminalSurface.NamedKeySendResult {
    var acceptedForTextBoxSubmit: Bool {
        switch self {
        case .sent, .queued:
            return true
        case .unknownKey, .inputQueueFull, .surfaceUnavailable, .processExited:
            return false
        }
    }
}

@MainActor
final class TextBoxSubmitEventRunner {
    private static var active: [UUID: TextBoxSubmitEventRunner] = [:]
    private static var activeRunIDBySurface: [ObjectIdentifier: UUID] = [:]
    private static var queuedRunsBySurface: [ObjectIdentifier: [PendingRun]] = [:]
    private static var queuedSurfaceOrder: [ObjectIdentifier] = []
    private static var activePasteboardRunID: UUID?
    private static var isDrainingQueuedRuns = false

    private let id = UUID()
    private let events: [TextBoxSubmit.DispatchEvent]
    private let surface: TextBoxSubmitSurfaceControlling
    private let surfaceKey: ObjectIdentifier
    private let usesPasteboard: Bool
    private var onComplete: ((TextBoxSubmit.CompletionContext) -> Void)?
    private var index = 0
    private var claudeImageTokenBaseline = 0
    private var visibleTextBaseline = ""
    private var clipboardReadBaseline = 0
    private var filePasteFallbackSatisfiedClipboardRead = false
    private var confirmedClaudeImageSubmissionTexts: [String: Int] = [:]
    private var observers: [NSObjectProtocol] = []
    private var waitTimeoutTimer: DispatchSourceTimer?
    private var releaseTickNotifications: (() -> Void)?
    private var releaseRenderedFrameNotifications: (() -> Void)?
    private var originalPasteboardItems: [PasteboardItemSnapshot]?
    private var temporaryPasteboardRestorationToken: TextBoxPasteboardRestorationToken?
    private var observationToken = UUID()

    private static var waitTimeoutSeconds: TimeInterval {
#if DEBUG
        if let override = TextBoxSubmit.debugWaitTimeoutSecondsOverride {
            return max(0, override)
        }
#endif
        return 15
    }

    private struct PasteboardItemSnapshot {
        let representations: [(type: NSPasteboard.PasteboardType, data: Data)]
    }

    private struct PendingRun {
        let events: [TextBoxSubmit.DispatchEvent]
        let surface: TextBoxSubmitSurfaceControlling
        let onComplete: ((TextBoxSubmit.CompletionContext) -> Void)?
        let usesPasteboard: Bool

        init(
            events: [TextBoxSubmit.DispatchEvent],
            surface: TextBoxSubmitSurfaceControlling,
            onComplete: ((TextBoxSubmit.CompletionContext) -> Void)?
        ) {
            self.events = events
            self.surface = surface
            self.onComplete = onComplete
            self.usesPasteboard = events.contains { event in
                if case .pasteFilePath = event { return true }
                return false
            }
        }
    }

    init(
        events: [TextBoxSubmit.DispatchEvent],
        surface: TextBoxSubmitSurfaceControlling,
        onComplete: ((TextBoxSubmit.CompletionContext) -> Void)?,
        usesPasteboard: Bool
    ) {
        self.events = events
        self.surface = surface
        self.surfaceKey = ObjectIdentifier(surface)
        self.onComplete = onComplete
        self.usesPasteboard = usesPasteboard
    }

    static func run(
        _ events: [TextBoxSubmit.DispatchEvent],
        via surface: TextBoxSubmitSurfaceControlling,
        onComplete: ((TextBoxSubmit.CompletionContext) -> Void)? = nil
    ) {
        let surfaceKey = ObjectIdentifier(surface)
        let pendingRun = PendingRun(events: events, surface: surface, onComplete: onComplete)
        guard activeRunIDBySurface[surfaceKey] == nil,
              queuedRunsBySurface[surfaceKey]?.isEmpty != false,
              !(pendingRun.usesPasteboard && activePasteboardRunID != nil) else {
            enqueue(pendingRun, for: surfaceKey)
#if DEBUG
            cmuxDebugLog("textbox.submit.queue surface=\(surfaceKey) count=\(queuedRunsBySurface[surfaceKey]?.count ?? 0)")
#endif
            return
        }
        start(pendingRun)
    }

    private static func start(_ pendingRun: PendingRun) {
        let runner = TextBoxSubmitEventRunner(
            events: pendingRun.events,
            surface: pendingRun.surface,
            onComplete: pendingRun.onComplete,
            usesPasteboard: pendingRun.usesPasteboard
        )
        active[runner.id] = runner
        activeRunIDBySurface[runner.surfaceKey] = runner.id
        if runner.usesPasteboard {
            activePasteboardRunID = runner.id
        }
        runner.processNext()
    }

    private static func enqueue(_ pendingRun: PendingRun, for surfaceKey: ObjectIdentifier) {
        if queuedRunsBySurface[surfaceKey]?.isEmpty != false,
           !queuedSurfaceOrder.contains(surfaceKey) {
            queuedSurfaceOrder.append(surfaceKey)
        }
        queuedRunsBySurface[surfaceKey, default: []].append(pendingRun)
    }

    private func processNext() {
        removeObservers()

        while index < events.count {
            let event = events[index]
#if DEBUG
            cmuxDebugLog("textbox.submit.event id=\(id.uuidString.prefix(5)) index=\(index) event=\(Self.debugDescription(for: event))")
#endif
            index += 1

            switch event {
            case .keyText(let text):
                guard surface.sendKeyText(text) else {
                    fail(.terminalWriteRejected)
                    return
                }
            case .pasteText(let text):
                guard surface.sendText(text) else {
                    fail(.terminalWriteRejected)
                    return
                }
            case .pasteFilePath(let path):
                guard pasteFilePath(path) else {
                    fail(.terminalWriteRejected)
                    return
                }
            case .namedKeyRepeat(let key, let count):
                guard count > 0 else { continue }
                for _ in 0..<count {
                    guard surface.sendNamedKey(key).acceptedForTextBoxSubmit else {
                        fail(.terminalWriteRejected)
                        return
                    }
                }
            case .namedKey(let key):
                guard surface.sendNamedKey(key).acceptedForTextBoxSubmit else {
                    fail(.terminalWriteRejected)
                    return
                }
            case .captureClipboardReadBaseline:
                clipboardReadBaseline = surface.clipboardReadGeneration
                filePasteFallbackSatisfiedClipboardRead = false
            case .waitForClipboardRead:
                waitForClipboardRead()
                return
            case .captureVisibleTextBaseline:
                visibleTextBaseline = surface.visibleText() ?? ""
            case .waitForVisibleText(let expectedText):
                waitForVisibleText(expectedText)
                return
            case .captureClaudeImageTokenBaseline:
                claudeImageTokenBaseline = Self.claudeImageTokenCount(in: surface.visibleText() ?? "")
            case .waitForClaudeImageToken(let expectedText):
                waitForClaudeImageToken(expectedText)
                return
            }
        }

        finish()
    }

    private func fail(_ failure: TextBoxSubmit.CompletionContext.Failure) {
        removeObservers()
        restorePasteboardIfNeeded()
        let completion = onComplete
        onComplete = nil
        Self.active[id] = nil
        if Self.activeRunIDBySurface[surfaceKey] == id {
            Self.activeRunIDBySurface[surfaceKey] = nil
        }
        if Self.activePasteboardRunID == id {
            Self.activePasteboardRunID = nil
        }
        completion?(TextBoxSubmit.CompletionContext(
            confirmedClaudeImageSubmissionTexts: confirmedClaudeImageSubmissionTexts,
            failure: failure
        ))
        Self.startQueuedRuns()
    }

    private func finish() {
        restorePasteboardIfNeeded()
        let completion = onComplete
        onComplete = nil
        Self.active[id] = nil
        if Self.activeRunIDBySurface[surfaceKey] == id {
            Self.activeRunIDBySurface[surfaceKey] = nil
        }
        if Self.activePasteboardRunID == id {
            Self.activePasteboardRunID = nil
        }
        completion?(TextBoxSubmit.CompletionContext(
            confirmedClaudeImageSubmissionTexts: confirmedClaudeImageSubmissionTexts
        ))
        Self.startQueuedRuns()
    }

    private static func startQueuedRuns() {
        guard !isDrainingQueuedRuns else { return }
        isDrainingQueuedRuns = true
        defer { isDrainingQueuedRuns = false }

        var madeProgress = true
        while madeProgress {
            madeProgress = false
            var index = 0
            while index < queuedSurfaceOrder.count {
                let surfaceKey = queuedSurfaceOrder[index]
                if activeRunIDBySurface[surfaceKey] != nil {
                    index += 1
                    continue
                }

                guard var queuedRuns = queuedRunsBySurface[surfaceKey],
                      let nextRun = queuedRuns.first else {
                    queuedRunsBySurface[surfaceKey] = nil
                    queuedSurfaceOrder.remove(at: index)
                    continue
                }
                if nextRun.usesPasteboard, activePasteboardRunID != nil {
                    index += 1
                    continue
                }

                queuedRuns.removeFirst()
                if queuedRuns.isEmpty {
                    queuedRunsBySurface[surfaceKey] = nil
                    queuedSurfaceOrder.remove(at: index)
                } else {
                    queuedRunsBySurface[surfaceKey] = queuedRuns
                    index += 1
                }
                madeProgress = true
                start(nextRun)
            }
        }
    }

#if DEBUG
    static func resetForTesting() {
        for runner in active.values {
            runner.cancelForTesting()
        }
        active.removeAll()
        activeRunIDBySurface.removeAll()
        queuedRunsBySurface.removeAll()
        queuedSurfaceOrder.removeAll()
        activePasteboardRunID = nil
        isDrainingQueuedRuns = false
    }

    private func cancelForTesting() {
        removeObservers()
        restorePasteboardIfNeeded()
        onComplete = nil
    }
#endif

    private func waitForVisibleText(_ expectedText: String) {
        if visibleTextReady(expectedText) {
#if DEBUG
            cmuxDebugLog("textbox.submit.wait.visible.ready id=\(id.uuidString.prefix(5)) expected=\(Self.debugText(expectedText))")
#endif
            processNext()
            return
        }

        observeTerminalUpdates { [weak self] in
            guard let self,
                  self.visibleTextReady(expectedText) else {
                return false
            }
#if DEBUG
            cmuxDebugLog("textbox.submit.wait.visible.observed id=\(self.id.uuidString.prefix(5)) expected=\(Self.debugText(expectedText))")
#endif
            self.processNext()
            return true
        } onExhausted: { [weak self] in
            guard let self else { return }
#if DEBUG
            cmuxDebugLog("textbox.submit.wait.visible.exhausted.continuing id=\(self.id.uuidString.prefix(5)) expected=\(Self.debugText(expectedText))")
#endif
            self.processNext()
        }
    }

    private func waitForClipboardRead() {
        if filePasteFallbackSatisfiedClipboardRead {
            filePasteFallbackSatisfiedClipboardRead = false
#if DEBUG
            cmuxDebugLog("textbox.submit.wait.clipboard.fallback id=\(id.uuidString.prefix(5)) baseline=\(clipboardReadBaseline)")
#endif
            processNext()
            return
        }

        if clipboardReadReady() {
#if DEBUG
            cmuxDebugLog("textbox.submit.wait.clipboard.ready id=\(id.uuidString.prefix(5)) baseline=\(clipboardReadBaseline)")
#endif
            processNext()
            return
        }

        guard let token = observeTerminalUpdates(
            { [weak self] in
                guard let self else { return false }
                if self.filePasteFallbackSatisfiedClipboardRead {
                    self.filePasteFallbackSatisfiedClipboardRead = false
#if DEBUG
                    cmuxDebugLog("textbox.submit.wait.clipboard.fallback.observed id=\(self.id.uuidString.prefix(5)) baseline=\(self.clipboardReadBaseline)")
#endif
                    self.processNext()
                    return true
                }
                guard self.clipboardReadReady() else {
                    return false
                }
#if DEBUG
                cmuxDebugLog("textbox.submit.wait.clipboard.observed id=\(self.id.uuidString.prefix(5)) baseline=\(self.clipboardReadBaseline)")
#endif
                self.processNext()
                return true
            },
            onExhausted: { [weak self] in
                guard let self else { return }
#if DEBUG
                cmuxDebugLog("textbox.submit.wait.clipboard.exhausted.continuing id=\(self.id.uuidString.prefix(5)) baseline=\(self.clipboardReadBaseline)")
#endif
                self.processNext()
            },
            performInitialCheck: false
        ) else {
            return
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidCompleteClipboardRead,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self, self.observationToken == token else { return }
                if let notificationSurface = notification.object as AnyObject? {
                    guard notificationSurface === self.surface as AnyObject else { return }
                }
                guard self.clipboardReadReady() else { return }
#if DEBUG
                cmuxDebugLog("textbox.submit.wait.clipboard.notification id=\(self.id.uuidString.prefix(5)) baseline=\(self.clipboardReadBaseline)")
#endif
                self.processNext()
            }
        })

        if clipboardReadReady() {
            processNext()
        }
    }

    private func waitForClaudeImageToken(_ expectedText: String) {
        if claudeImageTokenReady() {
#if DEBUG
            cmuxDebugLog(
                "textbox.submit.wait.image.ready id=\(id.uuidString.prefix(5)) " +
                "baseline=\(claudeImageTokenBaseline) expected=\(Self.debugText(expectedText))"
            )
#endif
            markClaudeImageTokenConfirmed(expectedText)
            processNext()
            return
        }

        observeTerminalUpdates { [weak self] in
            guard let self,
                  self.claudeImageTokenReady() else {
                return false
            }
#if DEBUG
            cmuxDebugLog(
                "textbox.submit.wait.image.observed id=\(self.id.uuidString.prefix(5)) " +
                "baseline=\(self.claudeImageTokenBaseline) expected=\(Self.debugText(expectedText))"
            )
#endif
            self.markClaudeImageTokenConfirmed(expectedText)
            self.processNext()
            return true
        } onExhausted: { [weak self] in
            guard let self else { return }
#if DEBUG
            cmuxDebugLog(
                "textbox.submit.wait.image.exhausted.continuing id=\(self.id.uuidString.prefix(5)) " +
                "baseline=\(self.claudeImageTokenBaseline) expected=\(Self.debugText(expectedText))"
            )
#endif
            self.processNext()
        }
    }

    private func markClaudeImageTokenConfirmed(_ expectedText: String) {
        confirmedClaudeImageSubmissionTexts[expectedText, default: 0] += 1
    }

    @discardableResult
    private func observeTerminalUpdates(
        _ check: @escaping @MainActor () -> Bool,
        onExhausted: (@MainActor () -> Void)? = nil,
        performInitialCheck: Bool = true
    ) -> UUID? {
        let center = NotificationCenter.default
        releaseTickNotifications = GhosttyApp.retainTickNotifications()
        releaseRenderedFrameNotifications = GhosttyNSView.retainRenderedFrameNotifications()
        let token = UUID()
        observationToken = token
        armObservationTimeout(
            token: token,
            timeoutSeconds: Self.waitTimeoutSeconds,
            onExhausted: onExhausted
        )

        @MainActor
        func checkIfCurrent() {
            guard observationToken == token else { return }
            let didComplete = check()
            guard !didComplete, observationToken == token else {
                return
            }
        }

        observers.append(center.addObserver(
            forName: .ghosttyDidTick,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard self != nil else { return }
                checkIfCurrent()
            }
        })

        observers.append(center.addObserver(
            forName: .ghosttyDidUpdateScrollbar,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self else { return }
                if let surfaceView = notification.object as? GhosttyNSView {
                    guard let expectedSurface = self.surface.textBoxSubmitTerminalSurface,
                          surfaceView.terminalSurface === expectedSurface else {
                        return
                    }
                }
                checkIfCurrent()
            }
        })

        observers.append(center.addObserver(
            forName: .ghosttyDidRenderFrame,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self else { return }
                if let surfaceView = notification.object as? GhosttyNSView {
                    guard let expectedSurface = self.surface.textBoxSubmitTerminalSurface,
                          surfaceView.terminalSurface === expectedSurface else {
                        return
                    }
                }
                checkIfCurrent()
            }
        })

        if let window = surface.textBoxSubmitObservationWindow {
            observers.append(center.addObserver(
                forName: NSWindow.didUpdateNotification,
                object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard self != nil else { return }
                checkIfCurrent()
            }
        })
        }

        if performInitialCheck {
            checkIfCurrent()
        }
        guard Self.active[id] === self,
              observationToken == token else {
            return nil
        }
        GhosttyApp.shared.scheduleTick()
        return token
    }

    private func armObservationTimeout(
        token: UUID,
        timeoutSeconds: TimeInterval,
        onExhausted: (@MainActor () -> Void)?
    ) {
        waitTimeoutTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        waitTimeoutTimer = timer
        timer.schedule(deadline: .now() + timeoutSeconds)
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.observationToken == token else {
                    return
                }
#if DEBUG
                cmuxDebugLog("textbox.submit.wait.timeout id=\(self.id.uuidString.prefix(5))")
#endif
                onExhausted?()
            }
        }
        timer.resume()
    }

    private func pasteFilePath(_ path: String) -> Bool {
        let pasteboard = NSPasteboard.general
        if originalPasteboardItems == nil {
            originalPasteboardItems = Self.snapshotPasteboardItems(pasteboard)
        } else if !TextBoxPasteboardRestorationGuard.isCurrentTemporaryWrite(
            pasteboard: pasteboard,
            token: temporaryPasteboardRestorationToken
        ) {
            originalPasteboardItems = Self.snapshotPasteboardItems(pasteboard)
            temporaryPasteboardRestorationToken = nil
        }

        let fileURL = URL(fileURLWithPath: path).standardizedFileURL
        pasteboard.clearContents()
        let wroteURL = pasteboard.writeObjects([fileURL as NSURL])
        if !wroteURL {
            pasteboard.clearContents()
            pasteboard.declareTypes([.fileURL, PasteboardFileURLReader.legacyFilenamesPboardType], owner: nil)
            _ = pasteboard.setString(fileURL.absoluteString, forType: .fileURL)
            _ = pasteboard.setPropertyList([fileURL.path], forType: PasteboardFileURLReader.legacyFilenamesPboardType)
        }
        temporaryPasteboardRestorationToken = TextBoxPasteboardRestorationGuard.token(
            afterWritingTemporaryFileURL: fileURL,
            to: pasteboard
        )

#if DEBUG
        cmuxDebugLog(
            "textbox.submit.pasteFile id=\(id.uuidString.prefix(5)) pathLength=\(fileURL.path.utf8.count) wroteURL=\(wroteURL ? 1 : 0) " +
            "types=\((pasteboard.types ?? []).map(\.rawValue).joined(separator: ","))"
        )
#endif

        let handled = surface.performBindingAction("paste_from_clipboard")
#if DEBUG
        cmuxDebugLog("textbox.submit.pasteFile.binding id=\(id.uuidString.prefix(5)) handled=\(handled ? 1 : 0)")
#endif
        if handled {
            return true
        } else {
            filePasteFallbackSatisfiedClipboardRead = true
            let sentFallback = surface.sendText(TerminalImageTransferPlanner.escapeForShell(path))
            restorePasteboardIfNeeded()
            return sentFallback
        }
    }

    private func restorePasteboardIfNeeded() {
        guard let originalPasteboardItems else { return }
        self.originalPasteboardItems = nil
        let pasteboard = NSPasteboard.general
        guard TextBoxPasteboardRestorationGuard.shouldRestore(
            pasteboard: pasteboard,
            token: temporaryPasteboardRestorationToken
        ) else {
            temporaryPasteboardRestorationToken = nil
            return
        }
        temporaryPasteboardRestorationToken = nil
        pasteboard.clearContents()
        guard !originalPasteboardItems.isEmpty else { return }
        let restoredItems = originalPasteboardItems.map { snapshot in
            let item = NSPasteboardItem()
            for representation in snapshot.representations {
                item.setData(representation.data, forType: representation.type)
            }
            return item
        }
        pasteboard.writeObjects(restoredItems)
    }

    private static func snapshotPasteboardItems(_ pasteboard: NSPasteboard) -> [PasteboardItemSnapshot] {
        (pasteboard.pasteboardItems ?? []).map { item in
            PasteboardItemSnapshot(
                representations: item.types.compactMap { type in
                    guard let data = item.data(forType: type) else { return nil }
                    return (type: type, data: data)
                }
            )
        }
    }

    private func claudeImageTokenReady() -> Bool {
        Self.claudeImageTokenCount(in: surface.visibleText() ?? "") > claudeImageTokenBaseline
    }

    private func clipboardReadReady() -> Bool {
        surface.clipboardReadGeneration > clipboardReadBaseline
    }

    private func visibleTextReady(_ expectedText: String) -> Bool {
        let visibleText = surface.visibleText() ?? ""
        return TextBoxSubmit.visibleTextReady(
            expectedText: expectedText,
            visibleText: visibleText,
            baseline: visibleTextBaseline
        )
    }

    private static func claudeImageTokenCount(in text: String) -> Int {
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: "[Image #", range: searchRange) {
            count += 1
            searchRange = range.upperBound..<text.endIndex
        }
        return count
    }

#if DEBUG
    private static func debugDescription(for event: TextBoxSubmit.DispatchEvent) -> String {
        switch event {
        case .keyText(let text):
            return "keyText(\(debugText(text)))"
        case .pasteText(let text):
            return "pasteText(\(debugText(text)))"
        case .pasteFilePath(let path):
            return "pasteFilePath(length:\(path.utf8.count))"
        case .namedKeyRepeat(let key, let count):
            return "namedKeyRepeat(\(key),\(count))"
        case .namedKey(let key):
            return "namedKey(\(key))"
        case .captureClipboardReadBaseline:
            return "captureClipboardReadBaseline"
        case .waitForClipboardRead:
            return "waitForClipboardRead"
        case .captureVisibleTextBaseline:
            return "captureVisibleTextBaseline"
        case .waitForVisibleText(let text):
            return "waitForVisibleText(\(debugText(text)))"
        case .captureClaudeImageTokenBaseline:
            return "captureClaudeImageTokenBaseline"
        case .waitForClaudeImageToken(let text):
            return "waitForClaudeImageToken(\(debugText(text)))"
        }
    }

    private static func debugText(_ text: String) -> String {
        "length:\(text.utf8.count),hasNewlines:\(text.contains(where: \.isNewline) ? 1 : 0)"
    }
#endif

    private func removeObservers() {
        observationToken = UUID()
        waitTimeoutTimer?.cancel()
        waitTimeoutTimer = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll(keepingCapacity: false)
        releaseTickNotifications?()
        releaseTickNotifications = nil
        releaseRenderedFrameNotifications?()
        releaseRenderedFrameNotifications = nil
    }
}

