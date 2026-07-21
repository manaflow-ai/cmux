import AppKit
import CMUXMobileCore
import CmuxCanvas
import CmuxCanvasUI
import CmuxControlSocket
import CmuxTerminal
import CmuxWorkspaceShare
import Combine
import Foundation

@MainActor
final class WorkspaceShareExporter {
    typealias SendFrame = @MainActor @Sendable (String, WorkspaceShareJSONValue) async -> Void

    private weak var workspace: Workspace?
    private weak var tabManager: TabManager?
    private let sendFrame: SendFrame
    private let cursorOverlay: WorkspaceShareCursorOverlayController
    private var layoutRevision: UInt64 = 0
    private var terminalTransportTracker = WorkspaceShareTerminalTransportTracker()
    private var terminalEmissionStateBySurfaceID: [UUID: MobileTerminalRenderGridEmissionState] = [:]
    private var documentsByPanelID: [UUID: WorkspaceShareTextDocument] = [:]
    private var documentCounterByPanelID: [UUID: UInt64] = [:]
    private var applyingRemoteTextPanelIDs: Set<UUID> = []
    private var deferredRemoteTextOperationsByPanelID: [UUID: [DeferredRemoteTextOperation]] = [:]
    private var remoteTextSelectionsByConnectionID: [String: WorkspaceShareTextSelection] = [:]
    private var remoteTextCaretViewsByConnectionID: [String: WorkspaceShareTextCaretOverlayView] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var textCancellablesByPanelID: [UUID: Set<AnyCancellable>] = [:]
    private var notificationObservers: [NSObjectProtocol] = []
    private var mouseMonitor: Any?
    private var previousAcceptsMouseMovedEvents: Bool?
    private var terminalFlushBarrier = WorkspaceShareTerminalFlushBarrier()
    private var terminalFlushScheduled = false
    private var snapshotScheduled = false
    private var snapshotInFlight = false
    private var snapshotRequestedWhileInFlight = false
    private var lastPointerSentAt: TimeInterval = 0
    private var browserRefreshTask: Task<Void, Never>?
    private var lastBrowserDataURLByPanelID: [UUID: String] = [:]
    private var releaseRenderedFrameNotifications: (() -> Void)?
    private var releaseTickNotifications: (() -> Void)?
    private var terminalSequenceTrackingID: UUID?

    init(
        workspace: Workspace,
        tabManager: TabManager,
        cursorOverlay: WorkspaceShareCursorOverlayController,
        sendFrame: @escaping SendFrame
    ) {
        self.workspace = workspace
        self.tabManager = tabManager
        self.cursorOverlay = cursorOverlay
        self.sendFrame = sendFrame
    }

    func start() async {
        guard let workspace else { return }
        releaseRenderedFrameNotifications = GhosttyNSView.retainRenderedFrameNotifications()
        releaseTickNotifications = GhosttyApp.retainTickNotifications()
        terminalSequenceTrackingID = MobileTerminalByteTee.shared.retainSequenceTracking()
        attachWorkspaceObservers(workspace)
        attachTerminalObservers()
        attachTextSelectionObserver()
        attachPointerMonitor()
        rewireTextObservers()
        await sendSnapshot()
        browserRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                await self?.emitChangedBrowserFrames()
            }
        }
    }

    func stop() {
        cancellables.removeAll()
        textCancellablesByPanelID.removeAll()
        browserRefreshTask?.cancel()
        browserRefreshTask = nil
        lastBrowserDataURLByPanelID.removeAll()
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()
        releaseRenderedFrameNotifications?()
        releaseRenderedFrameNotifications = nil
        releaseTickNotifications?()
        releaseTickNotifications = nil
        if let terminalSequenceTrackingID {
            MobileTerminalByteTee.shared.releaseSequenceTracking(terminalSequenceTrackingID)
            self.terminalSequenceTrackingID = nil
        }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        if let window = tabManager?.window,
           let previousAcceptsMouseMovedEvents {
            window.acceptsMouseMovedEvents = previousAcceptsMouseMovedEvents
        }
        cursorOverlay.clear()
        deferredRemoteTextOperationsByPanelID.removeAll()
        remoteTextSelectionsByConnectionID.removeAll()
        for view in remoteTextCaretViewsByConnectionID.values { view.removeFromSuperview() }
        remoteTextCaretViewsByConnectionID.removeAll()
    }

    func sendSnapshot() async {
        guard !snapshotInFlight, !terminalFlushScheduled else {
            snapshotRequestedWhileInFlight = true
            return
        }
        snapshotInFlight = true
        terminalFlushBarrier.beginSnapshot()
        defer {
            terminalFlushBarrier.endSnapshot()
            snapshotInFlight = false
            if snapshotRequestedWhileInFlight {
                snapshotRequestedWhileInFlight = false
                scheduleSnapshot()
            } else {
                schedulePendingTerminalFlushIfReady()
            }
        }
        guard let emission = await snapshotPayload(),
              let value = try? WorkspaceShareJSONValue.encode(SnapshotPayload(scene: emission.scene)) else { return }
        await sendFrame("workspace.snapshot", value)
        for frame in emission.terminalVTFrames {
            guard let encoded = try? WorkspaceShareJSONValue.encode(frame) else { continue }
            await sendFrame("terminal.vt", encoded)
        }
        for document in emission.textDocuments {
            guard let encoded = try? WorkspaceShareJSONValue.encode(
                TextDocumentFramePayload(document: document)
            ) else { continue }
            await sendFrame("textbox.document", encoded)
        }
        for (surfaceID, imageDataURL) in emission.browserImages {
            guard let encoded = try? WorkspaceShareJSONValue.encode(BrowserFramePayload(
                surfaceId: surfaceID.uuidString,
                imageDataUrl: imageDataURL
            )) else { continue }
            await sendFrame("panel.frame", encoded)
        }
    }

    func applyRemoteTextOperation(
        _ operation: WorkspaceShareTextOperation,
        clientID: String
    ) -> WorkspaceShareRemoteTextOperationResult {
        guard let panelID = UUID(uuidString: operation.docId),
              let panel = workspace?.terminalPanel(for: panelID),
              isShareableTextBox(panel) else { return .rejected(textSnapshot(docID: operation.docId)) }
        if panel.textBoxInputView?.hasMarkedText() == true {
            var deferred = deferredRemoteTextOperationsByPanelID[panelID] ?? []
            guard deferred.count < 128 else { return .rejected(textSnapshot(docID: operation.docId)) }
            deferred.append(DeferredRemoteTextOperation(operation: operation, clientID: clientID))
            deferredRemoteTextOperationsByPanelID[panelID] = deferred
            return .deferred
        }
        var document = documentsByPanelID[panelID]
            ?? WorkspaceShareTextDocument(docId: operation.docId, text: panel.textBoxContent)
        guard document.apply(operation, expectedClientID: clientID) else {
            return .rejected(document.snapshot)
        }
        documentsByPanelID[panelID] = document
        applyingRemoteTextPanelIDs.insert(panelID)
        let nextText = document.text
        panel.textBoxContent = nextText
        if let textView = panel.textBoxInputView {
            let selection = textView.selectedRange()
            textView.string = nextText
            let location = min(selection.location, (nextText as NSString).length)
            let length = min(selection.length, (nextText as NSString).length - location)
            textView.setSelectedRange(NSRange(location: location, length: length))
            textView.didChangeText()
        }
        applyingRemoteTextPanelIDs.remove(panelID)
        refreshRemoteTextCarets()
        return .accepted(operation: operation, revision: document.revision)
    }

    func applyRemoteTerminalInput(_ input: WorkspaceShareTerminalInput) -> Bool {
        guard input.layoutRevision == layoutRevision,
              let panelID = UUID(uuidString: input.surfaceId),
              let workspace,
              let topology = shareTopology(workspace: workspace),
              topology.containsSelectedSurface(panelID),
              let panel = workspace.terminalPanel(for: panelID) else { return false }
        switch input.kind {
        case .text:
            return panel.sendText(input.data)
        case .key:
            return panel.sendNamedKeyResult(input.data).accepted
        }
    }

    func textSnapshot(docID: String) -> WorkspaceShareTextSnapshot? {
        guard let panelID = UUID(uuidString: docID),
              let panel = workspace?.terminalPanel(for: panelID),
              isShareableTextBox(panel) else { return nil }
        let document = documentsByPanelID[panelID]
            ?? WorkspaceShareTextDocument(docId: docID, text: panel.textBoxContent)
        documentsByPanelID[panelID] = document
        return document.snapshot
    }

    func updateRemotePointer(_ pointer: WorkspaceShareRemotePointer) {
        guard pointer.layoutRevision == layoutRevision else { return }
        cursorOverlay.update(pointer: pointer)
    }

    func updateRemoteChat(_ message: WorkspaceShareChatMessage) {
        cursorOverlay.update(message: message)
    }

    func updateRemoteTextSelection(_ selection: WorkspaceShareTextSelection) {
        remoteTextSelectionsByConnectionID[selection.participant.connectionId] = selection
        refreshRemoteTextCarets()
    }

    func removeRemotePointer(connectionID: String) {
        cursorOverlay.remove(connectionID: connectionID)
        remoteTextSelectionsByConnectionID[connectionID] = nil
        remoteTextCaretViewsByConnectionID.removeValue(forKey: connectionID)?.removeFromSuperview()
    }

    private func attachWorkspaceObservers(_ workspace: Workspace) {
        workspace.$layoutMode
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleSnapshot() }
            .store(in: &cancellables)
        workspace.canvasModel.revisionPublisher
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleSnapshot() }
            .store(in: &cancellables)
        workspace.paneLayoutVersionPublisher
            .sink { [weak self] _ in self?.scheduleSnapshot() }
            .store(in: &cancellables)
        workspace.panelsPublisher
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.rewireTextObservers()
                    self?.scheduleSnapshot()
                }
            }
            .store(in: &cancellables)
        workspace.$panelTitles
            .sink { [weak self] _ in self?.scheduleSnapshot() }
            .store(in: &cancellables)
        workspace.$panelCustomTitles
            .sink { [weak self] _ in self?.scheduleSnapshot() }
            .store(in: &cancellables)
        workspace.$title
            .sink { [weak self] _ in self?.scheduleSnapshot() }
            .store(in: &cancellables)
        workspace.$customTitle
            .sink { [weak self] _ in self?.scheduleSnapshot() }
            .store(in: &cancellables)
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: .workspacePaneGeometryDidChange,
            object: workspace,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSnapshot() }
        })
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: .workspaceCanvasViewportGeometryDidChange,
            object: workspace,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshCursorCoordinateSpace() }
        })
    }

    private func attachTerminalObservers() {
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidRenderFrame,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let surfaceID = (notification.object as? GhosttyNSView)?.terminalSurface?.id else { return }
                self?.scheduleTerminalFlush(surfaceIDs: [surfaceID])
            }
        })
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidTick,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleTerminalFlush(surfaceIDs: self?.selectedTerminalPanelIDs() ?? [])
            }
        })
    }

    private func attachTextSelectionObserver() {
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let textView = notification.object as? TextBoxInputTextView,
                      !textView.hasMarkedText(),
                      let panel = self.workspace?.panels.values.compactMap({ $0 as? TerminalPanel })
                        .first(where: { $0.textBoxInputView === textView }),
                      panel.isTextBoxActive else { return }
                let selection = textView.selectedRange()
                let payload = TextSelectionPayload(
                    docId: panel.id.uuidString,
                    anchorUTF16: selection.location,
                    headUTF16: selection.location + selection.length
                )
                guard let value = try? WorkspaceShareJSONValue.encode(payload) else { return }
                Task { @MainActor in await self.sendFrame("textbox.selection", value) }
            }
        })
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let textView = notification.object as? TextBoxInputTextView,
                      !textView.hasMarkedText(),
                      let panel = self.workspace?.panels.values.compactMap({ $0 as? TerminalPanel })
                        .first(where: { $0.textBoxInputView === textView }) else { return }
                Task { @MainActor [weak self] in
                    await self?.flushDeferredRemoteTextOperations(panelID: panel.id)
                    self?.refreshRemoteTextCarets()
                }
            }
        })
    }

    private func attachPointerMonitor() {
        guard let window = tabManager?.window else { return }
        previousAcceptsMouseMovedEvents = window.acceptsMouseMovedEvents
        window.acceptsMouseMovedEvents = true
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handlePointerEvent(event)
            }
            return event
        }
    }

    private func handlePointerEvent(_ event: NSEvent) {
        guard let workspace,
              let window = tabManager?.window,
              event.window === window,
              let contentView = window.contentView else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPointerSentAt >= 1.0 / 30.0 else { return }
        let payload: PointerPayload
        if workspace.layoutMode == .canvas {
            guard let bounds = canvasContentBounds(workspace),
                  let rootView = workspace.canvasModel.viewport as? CanvasRootView else { return }
            let point = contentView.convert(event.locationInWindow, from: nil)
            guard let canvasPoint = rootView.canvasPoint(from: point, in: contentView) else { return }
            let x = (Double(canvasPoint.x) - bounds.x) / bounds.width
            let y = (Double(canvasPoint.y) - bounds.y) / bounds.height
            guard (0...1).contains(x), (0...1).contains(y) else { return }
            let targetID = workspace.canvasModel.layout.topPane(at: CanvasPoint(
                x: Double(canvasPoint.x),
                y: Double(canvasPoint.y)
            ))?.rawValue.uuidString
            payload = PointerPayload(
                x: x,
                y: y,
                layoutRevision: layoutRevision,
                targetId: targetID
            )
        } else {
            let snapshot = workspace.bonsplitController.layoutSnapshot()
            guard snapshot.containerFrame.width > 1, snapshot.containerFrame.height > 1 else { return }
            let point = contentView.convert(event.locationInWindow, from: nil)
            let x = (Double(point.x) - snapshot.containerFrame.x) / snapshot.containerFrame.width
            let topDownY = Self.topDownY(
                pointY: Double(point.y),
                height: Double(contentView.bounds.height),
                isFlipped: contentView.isFlipped
            )
            let y = (topDownY - snapshot.containerFrame.y) / snapshot.containerFrame.height
            guard (0...1).contains(x), (0...1).contains(y) else { return }
            let targetID = snapshot.panes.first(where: { pane in
                let localX = snapshot.containerFrame.x + x * snapshot.containerFrame.width
                let localY = snapshot.containerFrame.y + y * snapshot.containerFrame.height
                return localX >= pane.frame.x && localX <= pane.frame.x + pane.frame.width
                    && localY >= pane.frame.y && localY <= pane.frame.y + pane.frame.height
            })?.paneId
            payload = PointerPayload(
                x: x,
                y: y,
                layoutRevision: layoutRevision,
                targetId: targetID
            )
        }
        lastPointerSentAt = now
        guard let value = try? WorkspaceShareJSONValue.encode(payload) else { return }
        Task { @MainActor in await sendFrame("presence.pointer", value) }
    }

    private func rewireTextObservers() {
        guard let workspace else { return }
        let panels = workspace.panels.values.compactMap { $0 as? TerminalPanel }
        let liveIDs = Set(panels.map(\.id))
        for panelID in textCancellablesByPanelID.keys where !liveIDs.contains(panelID) {
            textCancellablesByPanelID[panelID] = nil
            documentsByPanelID[panelID] = nil
            documentCounterByPanelID[panelID] = nil
        }
        for panel in panels where textCancellablesByPanelID[panel.id] == nil {
            var panelCancellables: Set<AnyCancellable> = []
            panel.$textBoxContent
                .sink { [weak self, weak panel] content in
                    guard let self, let panel else { return }
                    self.handleLocalTextChange(panel: panel, content: content)
                }
                .store(in: &panelCancellables)
            panel.$isTextBoxActive
                .sink { [weak self, weak panel] active in
                    guard let self, let panel else { return }
                    if active, self.documentsByPanelID[panel.id] == nil {
                        self.documentsByPanelID[panel.id] = WorkspaceShareTextDocument(
                            docId: panel.id.uuidString,
                            text: panel.textBoxContent
                        )
                    }
                    self.scheduleSnapshot()
                }
                .store(in: &panelCancellables)
            textCancellablesByPanelID[panel.id] = panelCancellables
        }
    }

    private func handleLocalTextChange(panel: TerminalPanel, content: String) {
        guard isShareableTextBox(panel),
              panel.textBoxInputView?.hasMarkedText() != true,
              !applyingRemoteTextPanelIDs.contains(panel.id) else { return }
        guard var document = documentsByPanelID[panel.id] else {
            documentsByPanelID[panel.id] = WorkspaceShareTextDocument(
                docId: panel.id.uuidString,
                text: content
            )
            return
        }
        guard document.text != content else { return }
        var counter = documentCounterByPanelID[panel.id] ?? 0
        let operations = document.localChange(
            to: content,
            clientID: "host-\(panel.id.uuidString)",
            counter: &counter
        )
        documentCounterByPanelID[panel.id] = counter
        documentsByPanelID[panel.id] = document
        for operation in operations {
            let payload = TextOperationPayload(operation: operation, revision: document.revision)
            guard let value = try? WorkspaceShareJSONValue.encode(payload) else { continue }
            Task { @MainActor in await sendFrame("textbox.operation", value) }
        }
    }

    private func flushDeferredRemoteTextOperations(panelID: UUID) async {
        guard let operations = deferredRemoteTextOperationsByPanelID.removeValue(forKey: panelID) else { return }
        for deferred in operations {
            switch applyRemoteTextOperation(deferred.operation, clientID: deferred.clientID) {
            case let .accepted(operation, revision):
                let payload = TextOperationPayload(operation: operation, revision: revision)
                guard let value = try? WorkspaceShareJSONValue.encode(payload) else { continue }
                await sendFrame("textbox.operation", value)
            case let .rejected(snapshot):
                guard let snapshot,
                      let value = try? WorkspaceShareJSONValue.encode(
                        TextDocumentFramePayload(document: snapshot)
                      ) else { continue }
                await sendFrame("textbox.document", value)
            case .deferred:
                break
            }
        }
    }

    private func refreshRemoteTextCarets() {
        guard let workspace else { return }
        let liveConnectionIDs = Set(remoteTextSelectionsByConnectionID.keys)
        for connectionID in remoteTextCaretViewsByConnectionID.keys where !liveConnectionIDs.contains(connectionID) {
            remoteTextCaretViewsByConnectionID.removeValue(forKey: connectionID)?.removeFromSuperview()
        }
        for (connectionID, selection) in remoteTextSelectionsByConnectionID {
            guard let panelID = UUID(uuidString: selection.docId),
                  let panel = workspace.terminalPanel(for: panelID),
                  isShareableTextBox(panel),
                  let textView = panel.textBoxInputView else {
                remoteTextCaretViewsByConnectionID.removeValue(forKey: connectionID)?.removeFromSuperview()
                continue
            }
            let caret = remoteTextCaretViewsByConnectionID[connectionID]
                ?? WorkspaceShareTextCaretOverlayView(participant: selection.participant)
            if caret.superview !== textView {
                caret.removeFromSuperview()
                textView.addSubview(caret)
            }
            remoteTextCaretViewsByConnectionID[connectionID] = caret
            caret.update(positionUTF16: selection.headUTF16, in: textView)
        }
    }

    private func scheduleSnapshot() {
        guard !snapshotScheduled else { return }
        snapshotScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            snapshotScheduled = false
            await sendSnapshot()
        }
    }

    private func scheduleTerminalFlush(surfaceIDs: Set<UUID>) {
        terminalFlushBarrier.enqueue(surfaceIDs)
        schedulePendingTerminalFlushIfReady()
    }

    private func schedulePendingTerminalFlushIfReady() {
        guard !terminalFlushScheduled,
              !snapshotInFlight,
              !snapshotScheduled else { return }
        terminalFlushScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            if snapshotInFlight || snapshotScheduled || snapshotRequestedWhileInFlight {
                terminalFlushScheduled = false
                if snapshotRequestedWhileInFlight, !snapshotInFlight, !snapshotScheduled {
                    snapshotRequestedWhileInFlight = false
                    scheduleSnapshot()
                }
                return
            }
            let surfaceIDs = terminalFlushBarrier.takePendingIfReady()
            guard !surfaceIDs.isEmpty else {
                terminalFlushScheduled = false
                return
            }
            await emitTerminalFrames(surfaceIDs: surfaceIDs)
            terminalFlushScheduled = false
            if snapshotRequestedWhileInFlight {
                snapshotRequestedWhileInFlight = false
                scheduleSnapshot()
            } else {
                schedulePendingTerminalFlushIfReady()
            }
        }
    }

    private func emitTerminalFrames(surfaceIDs: Set<UUID>) async {
        guard let workspace,
              let topology = shareTopology(workspace: workspace) else { return }
        let selectedIDs = selectedTerminalPanelIDs(topology: topology)
        for panelID in surfaceIDs.intersection(selectedIDs) {
            guard let panel = workspace.terminalPanel(for: panelID),
                  let frame = renderFrame(panel: panel, reset: false),
                  let encodedFrame = try? WorkspaceShareJSONValue.encode(frame) else { continue }
            await sendFrame("terminal.vt", encodedFrame)
        }
    }

    private func emitChangedBrowserFrames() async {
        guard let workspace,
              let topology = shareTopology(workspace: workspace) else { return }
        let images = await captureSelectedBrowserImages(topology: topology, workspace: workspace)
        lastBrowserDataURLByPanelID = lastBrowserDataURLByPanelID.filter { images[$0.key] != nil }
        for (surfaceID, imageDataURL) in images where lastBrowserDataURLByPanelID[surfaceID] != imageDataURL {
            lastBrowserDataURLByPanelID[surfaceID] = imageDataURL
            guard let encoded = try? WorkspaceShareJSONValue.encode(BrowserFramePayload(
                surfaceId: surfaceID.uuidString,
                imageDataUrl: imageDataURL
            )) else { continue }
            await sendFrame("panel.frame", encoded)
        }
    }

    private func snapshotPayload() async -> SnapshotEmission? {
        guard let workspace,
              let topology = shareTopology(workspace: workspace) else { return nil }
        layoutRevision &+= 1
        let browserImages = await captureSelectedBrowserImages(topology: topology, workspace: workspace)
        lastBrowserDataURLByPanelID = browserImages
        let scene = makeScene(
            workspace: workspace,
            topology: topology
        )
        refreshCursorCoordinateSpace(topology: topology)
        let selectedTerminalIDs = selectedTerminalPanelIDs(topology: topology)
        let liveTerminalIDs = Set(topology.panes.flatMap(\.surfaceIDs).filter {
            workspace.terminalPanel(for: $0) != nil
        })
        terminalTransportTracker.prune(keeping: Set(liveTerminalIDs.map(\.uuidString)))
        terminalEmissionStateBySurfaceID = terminalEmissionStateBySurfaceID.filter {
            liveTerminalIDs.contains($0.key)
        }
        let terminalVTFrames = selectedTerminalIDs.compactMap { panelID in
            workspace.terminalPanel(for: panelID).flatMap { renderFrame(panel: $0, reset: true) }
        }
        let textDocuments = topology.panes.compactMap { pane -> WorkspaceShareTextSnapshot? in
            guard let panelID = pane.selectedSurfaceID,
                  let panel = workspace.terminalPanel(for: panelID),
                  isShareableTextBox(panel) else { return nil }
            let document = documentsByPanelID[panelID]
                ?? WorkspaceShareTextDocument(docId: panelID.uuidString, text: panel.textBoxContent)
            documentsByPanelID[panelID] = document
            return document.snapshot
        }
        return SnapshotEmission(
            scene: scene,
            terminalVTFrames: terminalVTFrames,
            textDocuments: textDocuments,
            browserImages: browserImages
        )
    }

    private func makeScene(
        workspace: Workspace,
        topology: WorkspaceShareTopology
    ) -> WorkspaceShareScene {
        let panes = topology.panes.compactMap { pane -> WorkspaceShareScene.Pane? in
            let surfaces = pane.surfaceIDs.map { surfaceID -> WorkspaceShareScene.Surface in
                guard let panel = workspace.panels[surfaceID] else {
                    return WorkspaceShareScene.Surface(
                        id: surfaceID.uuidString,
                        title: String(localized: "workspaceShare.panel.unavailable", defaultValue: "Unavailable panel"),
                        kind: .unsupported,
                        docId: nil,
                        imageDataUrl: nil
                    )
                }
                let kind: WorkspaceShareScene.Surface.Kind
                var docID: String?
                if let terminal = panel as? TerminalPanel {
                    if isShareableTextBox(terminal) {
                        kind = .textbox
                        docID = terminal.id.uuidString
                    } else {
                        kind = .terminal
                    }
                } else if panel is BrowserPanel {
                    kind = .browser
                } else {
                    kind = .unsupported
                }
                return WorkspaceShareScene.Surface(
                    id: surfaceID.uuidString,
                    title: Self.boundedTitle(
                        panel.displayTitle,
                        fallback: String(localized: "workspaceShare.panel.untitled", defaultValue: "Untitled panel")
                    ),
                    kind: kind,
                    docId: docID,
                    imageDataUrl: nil
                )
            }
            guard let selected = pane.selectedSurfaceID,
                  surfaces.contains(where: { $0.id == selected.uuidString }) else { return nil }
            return WorkspaceShareScene.Pane(
                id: pane.paneID.uuidString,
                frame: WorkspaceShareScene.Frame(
                    x: pane.frame.x,
                    y: pane.frame.y,
                    width: pane.frame.width,
                    height: pane.frame.height
                ),
                selectedSurfaceId: selected.uuidString,
                surfaces: surfaces
            )
        }
        return WorkspaceShareScene(
            workspaceId: workspace.id.uuidString,
            workspaceTitle: Self.boundedTitle(
                workspace.customTitle ?? workspace.title,
                fallback: String(localized: "workspaceShare.workspace.untitled", defaultValue: "Workspace")
            ),
            layoutRevision: layoutRevision,
            width: topology.width,
            height: topology.height,
            panes: panes
        )
    }

    private func captureSelectedBrowserImages(
        topology: WorkspaceShareTopology,
        workspace: Workspace
    ) async -> [UUID: String] {
        var images: [UUID: String] = [:]
        for panelID in topology.panes.compactMap(\.selectedSurfaceID) {
            guard let browser = workspace.browserPanel(for: panelID),
                  let image = try? await browser.captureAutomationVisibleViewportSnapshot(),
                  let dataURL = Self.browserDataURL(image) else { continue }
            images[panelID] = dataURL
        }
        return images
    }

    private func renderFrame(
        panel: TerminalPanel,
        reset: Bool
    ) -> WorkspaceShareTerminalVTFrame? {
        let surfaceID = panel.id.uuidString
        let startsNewStream = reset || terminalTransportTracker.requiresSnapshot(surfaceId: surfaceID)
        let previousEmissionState = startsNewStream ? nil : terminalEmissionStateBySurfaceID[panel.id]
        let sourceSequence = MobileTerminalByteTee.shared.currentSequence(surfaceID: panel.id) ?? 0
        guard let fullFrame = panel.surface.mobileRenderGridFrame(
            stateSeq: sourceSequence,
            full: true,
            includeTheme: startsNewStream || previousEmissionState == nil
        )?.frame,
        let emission = try? fullFrame.renderGridEmission(
            comparedTo: previousEmissionState
        ) else { return nil }

        let kind: WorkspaceShareTerminalVTFrame.Kind = emission.frame.full ? .snapshot : .patch
        let bytes = kind == .snapshot
            ? emission.frame.vtReplacementBytes()
            : emission.frame.vtPatchBytes()
        guard let payload = try? terminalTransportTracker.makeFrame(
            surfaceId: surfaceID,
            kind: kind,
            columns: emission.frame.columns,
            rows: emission.frame.rows,
            data: bytes
        ) else { return nil }

        terminalEmissionStateBySurfaceID[panel.id] = emission.state
        return payload
    }

    private func selectedTerminalPanelIDs(
        topology providedTopology: WorkspaceShareTopology? = nil
    ) -> Set<UUID> {
        guard let workspace,
              let topology = providedTopology ?? shareTopology(workspace: workspace) else { return [] }
        return Set(topology.panes.compactMap(\.selectedSurfaceID).filter {
            workspace.terminalPanel(for: $0) != nil
        })
    }

    private func shareTopology(workspace: Workspace) -> WorkspaceShareTopology? {
        if workspace.layoutMode == .canvas {
            let panes = workspace.canvasModel.persistablePanes.map { pane in
                WorkspaceShareTopology.Pane(
                    paneID: pane.paneId,
                    frame: WorkspaceShareTopology.Frame(pane.frame),
                    surfaceIDs: pane.panelIds,
                    selectedSurfaceID: pane.selectedPanelId
                )
            }
            return WorkspaceShareTopology.canvas(panes: panes)
        }

        guard let tabManager else { return nil }
        let snapshot = TerminalController.shared.controlPaneList(
            workspace: workspace,
            tabManager: tabManager
        )
        let layout = workspace.bonsplitController.layoutSnapshot()
        guard snapshot.containerWidth.isFinite,
              snapshot.containerHeight.isFinite,
              snapshot.containerWidth > 1,
              snapshot.containerHeight > 1 else { return nil }
        let panes = snapshot.panes.compactMap { pane -> WorkspaceShareTopology.Pane? in
            guard let pixelFrame = pane.pixelFrame else { return nil }
            let frame = WorkspaceShareTopology.Frame(
                x: pixelFrame.x - layout.containerFrame.x,
                y: pixelFrame.y - layout.containerFrame.y,
                width: pixelFrame.width,
                height: pixelFrame.height
            )
            guard frame.isValid else { return nil }
            return WorkspaceShareTopology.Pane(
                paneID: pane.paneID,
                frame: frame,
                surfaceIDs: pane.surfaceIDs,
                selectedSurfaceID: pane.selectedSurfaceID
            )
        }
        return WorkspaceShareTopology(
            width: snapshot.containerWidth,
            height: snapshot.containerHeight,
            panes: panes,
            canvasBounds: nil
        )
    }

    private func canvasContentBounds(_ workspace: Workspace) -> WorkspaceShareTopology.Frame? {
        guard workspace.layoutMode == .canvas,
              let bounds = workspace.canvasModel.contentBounds else { return nil }
        let frame = WorkspaceShareTopology.Frame(bounds)
        return frame.isValid ? frame : nil
    }

    private func refreshCursorCoordinateSpace(topology providedTopology: WorkspaceShareTopology? = nil) {
        guard let workspace else { return }
        if workspace.layoutMode == .canvas {
            guard let topology = providedTopology ?? shareTopology(workspace: workspace),
                  let canvasBounds = topology.canvasBounds,
                  let rootView = workspace.canvasModel.viewport as? CanvasRootView else { return }
            cursorOverlay.update(canvasRootView: rootView, canvasBounds: canvasBounds.cgRect)
        } else {
            let layout = workspace.bonsplitController.layoutSnapshot()
            cursorOverlay.update(containerFrame: CGRect(
                x: layout.containerFrame.x,
                y: layout.containerFrame.y,
                width: layout.containerFrame.width,
                height: layout.containerFrame.height
            ))
        }
    }

    private static func browserDataURL(_ image: NSImage) -> String? {
        let maxDimension: CGFloat = 1_280
        let scale = min(1, maxDimension / max(max(image.size.width, image.size.height), 1))
        let targetSize = NSSize(
            width: max(1, image.size.width * scale),
            height: max(1, image.size.height * scale)
        )
        let resized = NSImage(size: targetSize)
        resized.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1
        )
        resized.unlockFocus()
        guard let tiff = resized.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(
                using: .jpeg,
                properties: [.compressionFactor: 0.7]
              ),
              data.count <= 900_000 else { return nil }
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }

    private func isShareableTextBox(_ panel: TerminalPanel) -> Bool {
        panel.isTextBoxActive
            && panel.textBoxAttachments.isEmpty
            && panel.textBoxContent.count <= WorkspaceShareTextDocument.maximumSnapshotAtoms
    }

    private static func boundedTitle(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? fallback : trimmed).prefix(160))
    }

    nonisolated static func topDownY(pointY: Double, height: Double, isFlipped: Bool) -> Double {
        isFlipped ? pointY : height - pointY
    }
}

struct WorkspaceShareTopology: Equatable, Sendable {
    struct Frame: Equatable, Sendable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        init(_ rect: CGRect) {
            self.init(
                x: Double(rect.origin.x),
                y: Double(rect.origin.y),
                width: Double(rect.width),
                height: Double(rect.height)
            )
        }

        var isValid: Bool {
            x.isFinite && y.isFinite && width.isFinite && height.isFinite
                && width > 1 && height > 1
        }

        var maxX: Double { x + width }
        var maxY: Double { y + height }
        var cgRect: CGRect {
            CGRect(
                x: CGFloat(x),
                y: CGFloat(y),
                width: CGFloat(width),
                height: CGFloat(height)
            )
        }
    }

    struct Pane: Equatable, Sendable {
        let paneID: UUID
        let frame: Frame
        let surfaceIDs: [UUID]
        let selectedSurfaceID: UUID?
    }

    let width: Double
    let height: Double
    let panes: [Pane]
    /// The unnormalized union in durable canvas coordinates. Nil for splits.
    let canvasBounds: Frame?

    init(width: Double, height: Double, panes: [Pane], canvasBounds: Frame?) {
        self.width = width
        self.height = height
        self.panes = panes
        self.canvasBounds = canvasBounds
    }

    static func canvas(panes: [Pane]) -> WorkspaceShareTopology? {
        guard let first = panes.first,
              panes.allSatisfy({ pane in
                  pane.frame.isValid
                      && !pane.surfaceIDs.isEmpty
                      && pane.selectedSurfaceID.map { pane.surfaceIDs.contains($0) } == true
              }) else { return nil }
        let minX = panes.dropFirst().reduce(first.frame.x) { min($0, $1.frame.x) }
        let minY = panes.dropFirst().reduce(first.frame.y) { min($0, $1.frame.y) }
        let maxX = panes.dropFirst().reduce(first.frame.maxX) { max($0, $1.frame.maxX) }
        let maxY = panes.dropFirst().reduce(first.frame.maxY) { max($0, $1.frame.maxY) }
        let bounds = Frame(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        guard bounds.isValid else { return nil }
        return WorkspaceShareTopology(
            width: bounds.width,
            height: bounds.height,
            panes: panes.map { pane in
                Pane(
                    paneID: pane.paneID,
                    frame: Frame(
                        x: pane.frame.x - bounds.x,
                        y: pane.frame.y - bounds.y,
                        width: pane.frame.width,
                        height: pane.frame.height
                    ),
                    surfaceIDs: pane.surfaceIDs,
                    selectedSurfaceID: pane.selectedSurfaceID
                )
            },
            canvasBounds: bounds
        )
    }

    func containsSelectedSurface(_ surfaceID: UUID) -> Bool {
        panes.contains { pane in
            pane.selectedSurfaceID == surfaceID && pane.surfaceIDs.contains(surfaceID)
        }
    }
}

private struct DeferredRemoteTextOperation: Sendable {
    let operation: WorkspaceShareTextOperation
    let clientID: String
}

private struct SnapshotPayload: Encodable, Sendable {
    let scene: WorkspaceShareScene
}

private struct SnapshotEmission: Sendable {
    let scene: WorkspaceShareScene
    let terminalVTFrames: [WorkspaceShareTerminalVTFrame]
    let textDocuments: [WorkspaceShareTextSnapshot]
    let browserImages: [UUID: String]
}

private struct TextOperationPayload: Encodable, Sendable {
    let operation: WorkspaceShareTextOperation
    let revision: UInt64
}

private struct TextSelectionPayload: Encodable, Sendable {
    let docId: String
    let anchorUTF16: Int
    let headUTF16: Int
}

private struct PointerPayload: Encodable, Sendable {
    let x: Double
    let y: Double
    let layoutRevision: UInt64
    let targetId: String?
}

private struct TextDocumentFramePayload: Encodable, Sendable {
    let document: WorkspaceShareTextSnapshot
}

private struct BrowserFramePayload: Encodable, Sendable {
    let surfaceId: String
    let imageDataUrl: String
}

enum WorkspaceShareRemoteTextOperationResult {
    case accepted(operation: WorkspaceShareTextOperation, revision: UInt64)
    case deferred
    case rejected(WorkspaceShareTextSnapshot?)
}

@MainActor
private final class WorkspaceShareTextCaretOverlayView: NSView {
    private let lineView = NSView(frame: .zero)
    private let nameLabel = NSTextField(labelWithString: "")

    init(participant: WorkspaceShareRemotePointer.Participant) {
        super.init(frame: .zero)
        let color = Self.color(index: participant.color)
        wantsLayer = true
        lineView.wantsLayer = true
        lineView.layer?.backgroundColor = color.cgColor
        nameLabel.stringValue = participant.displayName
        nameLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        nameLabel.textColor = .black
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.wantsLayer = true
        nameLabel.layer?.backgroundColor = color.cgColor
        nameLabel.layer?.cornerRadius = 3
        addSubview(lineView)
        addSubview(nameLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(positionUTF16: Int, in textView: NSTextView) {
        guard let caretRect = Self.caretRect(positionUTF16: positionUTF16, in: textView) else {
            isHidden = true
            return
        }
        isHidden = false
        let labelHeight: CGFloat = 15
        let labelWidth = min(130, max(28, ceil(nameLabel.intrinsicContentSize.width) + 8))
        let width = max(labelWidth, 2)
        if textView.isFlipped {
            let originY = max(0, caretRect.minY - labelHeight)
            frame = NSRect(x: caretRect.minX, y: originY, width: width, height: labelHeight + caretRect.height)
            nameLabel.frame = NSRect(x: 0, y: 0, width: labelWidth, height: labelHeight)
            lineView.frame = NSRect(x: 0, y: labelHeight, width: 2, height: caretRect.height)
        } else {
            frame = NSRect(x: caretRect.minX, y: caretRect.minY, width: width, height: labelHeight + caretRect.height)
            lineView.frame = NSRect(x: 0, y: 0, width: 2, height: caretRect.height)
            nameLabel.frame = NSRect(x: 0, y: caretRect.height, width: labelWidth, height: labelHeight)
        }
    }

    private static func caretRect(positionUTF16: Int, in textView: NSTextView) -> NSRect? {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let length = (textView.string as NSString).length
        let position = min(max(0, positionUTF16), length)
        let origin = textView.textContainerOrigin
        if length == 0 || (position == length && layoutManager.extraLineFragmentTextContainer === textContainer) {
            let extra = layoutManager.extraLineFragmentRect
            let height = max(extra.height, textView.font?.boundingRectForFont.height ?? 14)
            return NSRect(x: origin.x + extra.minX, y: origin.y + extra.minY, width: 2, height: height)
        }
        let characterIndex = min(position, length - 1)
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let glyph = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1),
            in: textContainer
        )
        let x = position == length ? glyph.maxX : glyph.minX
        return NSRect(
            x: origin.x + x,
            y: origin.y + line.minY,
            width: 2,
            height: max(line.height, textView.font?.boundingRectForFont.height ?? 14)
        )
    }

    private static func color(index: Int) -> NSColor {
        let palette: [NSColor] = [
            NSColor(calibratedRed: 1, green: 0.36, blue: 0.48, alpha: 1),
            NSColor(calibratedRed: 0.31, green: 0.89, blue: 0.76, alpha: 1),
            NSColor(calibratedRed: 0.49, green: 0.55, blue: 1, alpha: 1),
            NSColor(calibratedRed: 1, green: 0.74, blue: 0.29, alpha: 1),
            NSColor(calibratedRed: 0.83, green: 0.47, blue: 1, alpha: 1),
            NSColor(calibratedRed: 0.33, green: 0.72, blue: 1, alpha: 1),
            NSColor(calibratedRed: 1, green: 0.5, blue: 0.31, alpha: 1),
            NSColor(calibratedRed: 0.41, green: 0.83, blue: 0.43, alpha: 1),
            NSColor(calibratedRed: 0.97, green: 0.42, blue: 0.83, alpha: 1),
            NSColor(calibratedRed: 0.19, green: 0.84, blue: 0.93, alpha: 1),
            NSColor(calibratedRed: 0.84, green: 0.85, blue: 0.3, alpha: 1),
            NSColor(calibratedRed: 0.67, green: 0.57, blue: 1, alpha: 1),
        ]
        return palette[Int(index.magnitude % UInt(palette.count))]
    }
}
