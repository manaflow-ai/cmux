import CmuxTerminal
import CmuxTerminalRenderCompositor
import CmuxTerminalRenderProtocol
import CmuxTerminalRenderTransport
import Foundation

/// Main-actor façade over one daemon-owned terminal and its disposable presentation.
@MainActor
final class PersistentTerminalExternalRuntime: TerminalExternalRuntime {
    private enum State {
        case binding
        case live
        case processExited
        case unavailable
    }

    private let client: any TerminalBackendClient
    private let launchResolver: TerminalSurfaceLaunchResolver
    private let launchRequest: TerminalSurfaceLaunchRequest
    private let initialColumns: UInt16
    private let initialRows: UInt16
    private let presentationRegistry: TerminalBackendPresentationRegistry
    private let presentationID = UUID()
    private let pixelFormat = TerminalRenderPixelFormat.bgra8Unorm
    private let colorSpace = TerminalRenderColorSpace.sRGB
    private let renderConfigSource: TerminalBackendRenderConfigSource?
    private let presentationConfigOverrides: Data
    private let clipboardWriter: (String) -> Void
    private var baseRenderConfigRevision: UInt64
    private var baseRenderConfig: Data
    private var backendDefaultConfig = Data()
    private var resolvedConfigRevision: UInt64
    private var resolvedConfig: Data

    private var state = State.binding
    private(set) var snapshot = TerminalExternalRuntimeSnapshot(lifecycle: .unavailable)
    private var queue: TerminalBackendMutationQueue
    private var nextSequence: UInt64 = 1
    private var binding: TerminalBackendTerminalBinding?
    private var resolvedRequest: TerminalBackendTerminalRequest?
    private var bindingTask: Task<TerminalBackendTerminalBinding, any Error>?
    private var drainTask: Task<Void, Never>?
    private var rendererEventTask: Task<Void, Never>?
    private var renderConfigTask: Task<Void, Never>?
    private var receiver: TerminalRenderFrameReceiver?
    private var receiveTask: Task<Void, Never>?
    private var compositor: TerminalRenderCompositorView?
    private var mount: TerminalBackendPresentationMount?
    private var attachedPresentation: TerminalExternalPresentation?
    private var currentWorkspaceID: UUID
    private var currentViewport: TerminalExternalViewport?
    private var pendingViewportWithoutMetrics: TerminalExternalViewport?
    private var focused = false
    private var visible = false
    private var preedit: String?
    private var backendPresentationOpen = false
    private var rendererReconfigureNeeded = false
    private var detached = false
    private var canonicalCloseRequested = false
    private var detachAfterCanonicalClose = false

    init(
        client: any TerminalBackendClient,
        launchResolver: TerminalSurfaceLaunchResolver,
        launchRequest: TerminalSurfaceLaunchRequest,
        initialColumns: UInt16 = 80,
        initialRows: UInt16 = 24,
        presentationRegistry: TerminalBackendPresentationRegistry,
        renderConfigSource: TerminalBackendRenderConfigSource? = nil,
        presentationConfigOverrides: Data = Data(),
        resolvedConfigRevision: UInt64 = 0,
        resolvedConfig: Data = Data(),
        queueCapacity: Int = 256,
        clipboardWriter: @escaping (String) -> Void = { text in
            GhosttyApp.terminalPasteboard.writeString(
                text,
                to: GHOSTTY_CLIPBOARD_STANDARD
            )
        }
    ) {
        self.client = client
        self.launchResolver = launchResolver
        self.launchRequest = launchRequest
        self.initialColumns = initialColumns
        self.initialRows = initialRows
        self.presentationRegistry = presentationRegistry
        self.renderConfigSource = renderConfigSource
        self.presentationConfigOverrides = presentationConfigOverrides
        self.clipboardWriter = clipboardWriter
        if let current = renderConfigSource?.current {
            self.baseRenderConfigRevision = current.revision
            self.baseRenderConfig = current.data
            self.resolvedConfigRevision = max(1, current.revision)
            self.resolvedConfig = TerminalBackendRenderConfigSource.layered(
                base: current.data,
                presentationOverrides: presentationConfigOverrides
            )
        } else {
            self.baseRenderConfigRevision = 0
            self.baseRenderConfig = resolvedConfig
            self.resolvedConfigRevision = resolvedConfigRevision
            self.resolvedConfig = TerminalBackendRenderConfigSource.layered(
                base: resolvedConfig,
                presentationOverrides: presentationConfigOverrides
            )
        }
        self.currentWorkspaceID = launchRequest.workspaceID
        self.queue = TerminalBackendMutationQueue(capacity: queueCapacity)
    }

    func attachPresentation(
        _ presentation: TerminalExternalPresentation
    ) -> any TerminalExternalPresentationLease {
        precondition(attachedPresentation == nil || attachedPresentation == presentation)
        attachedPresentation = presentation
        currentWorkspaceID = presentation.workspaceID
        detached = false
        let mount = presentationRegistry.register(surfaceID: presentation.surfaceID)
        self.mount = mount
        mount.onHostMounted = { [weak self] in
            guard let self, self.visible else { return }
            self.rendererReconfigureNeeded = true
            self.scheduleDrain()
        }
        startRendererEventsIfNeeded()
        startRenderConfigEventsIfNeeded()
        scheduleDrain()
        return TerminalBackendPresentationLease { [weak self] in
            Task { @MainActor in
                self?.detachPresentation()
            }
        }
    }

    func enqueue(
        _ mutation: TerminalExternalRuntimeMutation
    ) -> TerminalExternalIngressResult {
        switch state {
        case .processExited:
            return .rejected(.processExited)
        case .unavailable:
            return .rejected(.unavailable)
        case .binding, .live:
            break
        }
        guard !detached else { return .rejected(.unavailable) }
        if case .mouse = mutation,
           snapshot.cellMetrics == nil || !backendPresentationOpen {
            return .rejected(.unavailable)
        }
        let sequence = nextSequence
        guard queue.append(
            TerminalBackendQueuedMutation(sequence: sequence, mutation: mutation)
        ) else {
            return .rejected(.queueFull)
        }
        if case .closeCanonicalTerminal = mutation {
            canonicalCloseRequested = true
        }
        nextSequence &+= 1
        scheduleDrain()
        return .accepted(sequence: sequence)
    }

    func readScreenText(_ request: TerminalExternalScreenTextRequest) async -> String? {
        switch state {
        case .processExited, .unavailable:
            return snapshot.visibleText
        case .binding, .live:
            break
        }
        do {
            let binding = try await ensureBinding()
            let text = try await client.readScreenText(request, from: binding)
            replaceSnapshot(visibleText: text)
            return text
        } catch {
            markUnavailable()
            return snapshot.visibleText
        }
    }

    func readSelection() async -> TerminalExternalSelection? {
        switch state {
        case .processExited, .unavailable:
            return snapshot.selection
        case .binding, .live:
            break
        }
        do {
            let binding = try await ensureBinding()
            let selection = try await client.readSelection(from: binding)
            replaceSnapshot(selection: selection, selectionWasRead: true)
            return selection
        } catch {
            markUnavailable()
            return snapshot.selection
        }
    }

    private func scheduleDrain() {
        guard !detached, drainTask == nil else { return }
        drainTask = Task { @MainActor [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        defer {
            drainTask = nil
            if !detached && (!queue.isEmpty || rendererReconfigureNeeded) {
                scheduleDrain()
            }
        }
        do {
            _ = try await ensureBinding()
            while !detached {
                if rendererReconfigureNeeded {
                    rendererReconfigureNeeded = false
                    try await reconcileRenderer()
                    continue
                }
                guard let queued = queue.popFirst() else { return }
                try await apply(queued.mutation)
                if case .processExited = state { return }
            }
        } catch is CancellationError {
            return
        } catch {
            markUnavailable()
            if detachAfterCanonicalClose {
                canonicalCloseRequested = false
                detachPresentation()
            }
        }
    }

    private func ensureBinding() async throws -> TerminalBackendTerminalBinding {
        if let binding {
            if case .unavailable = state {
                state = .live
                replaceSnapshot(lifecycle: .live)
            }
            return binding
        }
        if let bindingTask { return try await bindingTask.value }
        let client = client
        let task = Task<TerminalBackendTerminalBinding, any Error> { @MainActor in
            let request: TerminalBackendTerminalRequest
            if let resolvedRequest {
                request = resolvedRequest
            } else {
                let launch = await launchResolver.resolveInstallingCommandShim(launchRequest)
                request = TerminalBackendTerminalRequest(
                    appWorkspaceID: launchRequest.workspaceID,
                    appSurfaceID: launchRequest.surfaceID,
                    workingDirectory: launch.workingDirectory,
                    command: launch.command,
                    arguments: launch.arguments,
                    environment: launch.environment,
                    initialInput: launch.initialInput,
                    waitAfterCommand: launch.waitAfterCommand,
                    columns: initialColumns,
                    rows: initialRows
                )
                resolvedRequest = request
            }
            return try await client.ensureTerminal(request)
        }
        bindingTask = task
        do {
            let binding = try await task.value
            bindingTask = nil
            let uxState = try await client.readTerminalUXState(from: binding)
            self.binding = binding
            currentWorkspaceID = binding.appWorkspaceID
            state = .live
            replaceSnapshot(
                lifecycle: .live,
                copyModeActive: uxState.copyModeActive,
                mouseTracking: uxState.mouseTracking,
                copyCursor: uxState.copyCursor,
                cursor: uxState.cursor,
                terminalUXWasRead: uxState.terminalUXWasRead,
                selection: uxState.selection,
                selectionWasRead: uxState.selectionWasRead,
                search: uxState.search,
                viewportState: uxState.viewportState
            )
            return binding
        } catch {
            bindingTask = nil
            binding = nil
            throw error
        }
    }

    private func apply(_ mutation: TerminalExternalRuntimeMutation) async throws {
        guard let binding else { throw TerminalBackendClientError.unavailable }
        updatePresentationState(for: mutation)

        if shouldApplyLocallyOnly(mutation) {
            if case .visibility(false) = mutation {
                await stopRendererPresentation()
            }
            return
        }

        let descriptor = try presentationDescriptor(for: mutation, binding: binding)
        let outcome = try await client.apply(
            mutation,
            to: binding,
            presentation: descriptor
        )
        if let updatedBinding = outcome.binding {
            self.binding = updatedBinding
            currentWorkspaceID = updatedBinding.appWorkspaceID
            resolvedRequest = resolvedRequest?.reparented(
                to: updatedBinding.appWorkspaceID
            )
        }
        replaceSnapshot(
            lifecycle: outcome.lifecycle,
            visibleText: outcome.visibleText,
            processMetadata: outcome.processMetadata,
            needsCloseConfirmation: outcome.needsCloseConfirmation,
            copyModeActive: outcome.copyModeActive,
            mouseTracking: outcome.mouseTracking,
            copyCursor: outcome.copyCursor,
            cursor: outcome.cursor,
            terminalUXWasRead: outcome.terminalUXWasRead,
            selection: outcome.selection,
            selectionWasRead: outcome.selectionWasRead,
            search: outcome.search,
            viewportState: outcome.viewportState
        )
        if let clipboardText = outcome.clipboardText, !clipboardText.isEmpty {
            clipboardWriter(clipboardText)
        }

        if let attachment = outcome.rendererAttachment {
            try await installRendererAttachment(attachment)
        }
        switch mutation {
        case .visibility(true), .resize, .reparent:
            if descriptor != nil, visible {
                backendPresentationOpen = true
            }
        case .visibility(false):
            await stopRendererPresentation()
        case .closeCanonicalTerminal:
            state = .processExited
            queue.removeAll()
            await stopRendererPresentation()
            if detachAfterCanonicalClose {
                detachPresentation()
            }
        default:
            break
        }
    }

    private func updatePresentationState(for mutation: TerminalExternalRuntimeMutation) {
        switch mutation {
        case .focus(let focused):
            self.focused = focused
        case .visibility(let visible):
            self.visible = visible
        case .resize(let viewport):
            currentViewport = viewport
            if snapshot.cellMetrics == nil {
                pendingViewportWithoutMetrics = viewport
            }
        case .preedit(let preedit):
            self.preedit = preedit
        case .input, .mouse, .bindingAction, .selection, .copyMode, .search, .scroll,
             .reparent, .closeCanonicalTerminal:
            break
        }
    }

    private func shouldApplyLocallyOnly(_ mutation: TerminalExternalRuntimeMutation) -> Bool {
        switch mutation {
        case .visibility(true):
            return !canPresent
        case .visibility(false):
            return !backendPresentationOpen
        case .resize:
            return visible && !canPresent
        case .preedit:
            return !backendPresentationOpen
        default:
            return false
        }
    }

    private var canPresent: Bool {
        visible && mount?.isMounted == true && currentViewport != nil
    }

    private func presentationDescriptor(
        for mutation: TerminalExternalRuntimeMutation,
        binding: TerminalBackendTerminalBinding
    ) throws -> TerminalBackendPresentationDescriptor? {
        let needsDescriptor: Bool
        switch mutation {
        case .focus, .visibility, .resize, .preedit, .mouse, .reparent:
            needsDescriptor = backendPresentationOpen || canPresent
        case .input, .bindingAction, .selection, .copyMode, .search, .scroll,
             .closeCanonicalTerminal:
            needsDescriptor = false
        }
        guard needsDescriptor, let viewport = currentViewport else { return nil }
        guard !resolvedConfig.isEmpty else {
            throw TerminalBackendClientError.presentationUnavailable
        }
        let receiver = try ensureReceiver(binding: binding, viewport: viewport)
        return TerminalBackendPresentationDescriptor(
            presentationID: presentationID,
            endpoint: receiver.endpoint,
            viewport: viewport,
            focused: focused,
            visible: visible,
            preedit: preedit,
            pixelFormat: pixelFormat,
            colorSpace: colorSpace,
            resolvedConfigRevision: resolvedConfigRevision,
            resolvedConfig: resolvedConfig
        )
    }

    private func ensureReceiver(
        binding: TerminalBackendTerminalBinding,
        viewport: TerminalExternalViewport
    ) throws -> TerminalRenderFrameReceiver {
        if let receiver { return receiver }
        guard let width = UInt32(exactly: viewport.widthPixels),
              let height = UInt32(exactly: viewport.heightPixels) else {
            throw TerminalBackendClientError.presentationUnavailable
        }
        let placeholder = try TerminalRenderPresentationFence(
            daemonInstanceID: binding.authority.daemonInstanceID.rawValue,
            rendererEpoch: 1,
            terminalID: binding.surfaceID.rawValue,
            terminalEpoch: 0,
            minimumTerminalSequence: 0,
            presentationID: presentationID,
            presentationGeneration: 1,
            width: width,
            height: height,
            pixelFormat: pixelFormat,
            colorSpace: colorSpace,
            completionRequirement: .producerCompleted
        )
        let receiver = try TerminalRenderFrameReceiver(initialFence: placeholder)
        self.receiver = receiver
        return receiver
    }

    private func reconcileRenderer() async throws {
        guard canPresent, let binding, let viewport = currentViewport else { return }
        guard !resolvedConfig.isEmpty else {
            throw TerminalBackendClientError.presentationUnavailable
        }
        let receiver = try ensureReceiver(binding: binding, viewport: viewport)
        let descriptor = TerminalBackendPresentationDescriptor(
            presentationID: presentationID,
            endpoint: receiver.endpoint,
            viewport: viewport,
            focused: focused,
            visible: visible,
            preedit: preedit,
            pixelFormat: pixelFormat,
            colorSpace: colorSpace,
            resolvedConfigRevision: resolvedConfigRevision,
            resolvedConfig: resolvedConfig
        )
        let outcome = try await client.apply(
            .resize(viewport),
            to: binding,
            presentation: descriptor
        )
        backendPresentationOpen = true
        state = .live
        replaceSnapshot(
            lifecycle: .live,
            visibleText: outcome.visibleText,
            processMetadata: outcome.processMetadata,
            needsCloseConfirmation: outcome.needsCloseConfirmation
        )
        if let attachment = outcome.rendererAttachment {
            try await installRendererAttachment(attachment)
        }
    }

    private func installRendererAttachment(
        _ attachment: TerminalBackendRendererAttachment
    ) async throws {
        guard visible, let receiver else { return }
        try await receiver.authorize(worker: attachment.worker)
        await receiver.updateFence(attachment.fence)

        let compositor: TerminalRenderCompositorView
        if let existing = self.compositor {
            existing.updateFence(attachment.fence)
            compositor = existing
        } else {
            let client = client
            compositor = try TerminalRenderCompositorView(fence: attachment.fence) { release in
                Task { await client.releaseFrame(release) }
            }
            self.compositor = compositor
        }
        mount?.install(compositor)
        replaceSnapshot(cellMetrics: attachment.cellMetrics)
        startReceivingFrames(receiver: receiver, compositor: compositor)
        coalesceViewportUsingExactMetrics(attachment.cellMetrics)
    }

    private func coalesceViewportUsingExactMetrics(
        _ metrics: TerminalExternalCellMetrics
    ) {
        guard let pending = pendingViewportWithoutMetrics ?? currentViewport,
              metrics.cellWidthPixels > 0,
              metrics.cellHeightPixels > 0 else { return }
        pendingViewportWithoutMetrics = nil
        let horizontalPadding = max(
            0,
            metrics.surfaceWidthPixels - metrics.columns * metrics.cellWidthPixels
        )
        let verticalPadding = max(
            0,
            metrics.surfaceHeightPixels - metrics.rows * metrics.cellHeightPixels
        )
        let columns = max(
            1,
            (pending.widthPixels - horizontalPadding) / metrics.cellWidthPixels
        )
        let rows = max(
            1,
            (pending.heightPixels - verticalPadding) / metrics.cellHeightPixels
        )
        guard pending.proposedColumns != columns || pending.proposedRows != rows else {
            return
        }
        currentViewport = TerminalExternalViewport(
            widthPoints: pending.widthPoints,
            heightPoints: pending.heightPoints,
            widthPixels: pending.widthPixels,
            heightPixels: pending.heightPixels,
            xScale: pending.xScale,
            yScale: pending.yScale,
            proposedColumns: columns,
            proposedRows: rows
        )
        rendererReconfigureNeeded = true
    }

    private func startReceivingFrames(
        receiver: TerminalRenderFrameReceiver,
        compositor: TerminalRenderCompositorView
    ) {
        receiveTask?.cancel()
        receiveTask = Task { @MainActor [weak self, receiver, compositor] in
            do {
                while !Task.isCancelled {
                    switch try await receiver.receive(
                        timeoutMilliseconds: TerminalRenderFrameReceiver
                            .maximumReceiveTimeoutMilliseconds
                    ) {
                    case .frame(let frame):
                        _ = await compositor.enqueue(frame)
                    case .timedOut, .dropped:
                        continue
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, !self.detached, self.visible else { return }
                self.rendererReconfigureNeeded = true
                self.scheduleDrain()
            }
        }
    }

    private func startRendererEventsIfNeeded() {
        guard rendererEventTask == nil else { return }
        rendererEventTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, !self.detached {
                let events = await self.client.rendererEvents()
                for await event in events {
                    guard !Task.isCancelled, !self.detached else { return }
                    await self.handleRendererEvent(event)
                }
                guard !Task.isCancelled, !self.detached else { return }
                await self.rotateReceiver()
                self.rendererReconfigureNeeded = true
                self.scheduleDrain()
                await Task.yield()
            }
        }
    }

    private func startRenderConfigEventsIfNeeded() {
        guard renderConfigTask == nil, let renderConfigSource else { return }
        renderConfigTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let updates = renderConfigSource.updates()
            for await update in updates {
                guard !Task.isCancelled, !self.detached else { return }
                guard update.revision != self.baseRenderConfigRevision else { continue }
                await self.installBaseRenderConfig(update)
            }
        }
    }

    private func installBaseRenderConfig(
        _ update: TerminalBackendRenderConfigSnapshot
    ) async {
        baseRenderConfigRevision = update.revision
        baseRenderConfig = update.data
        resolvedConfigRevision &+= 1
        if resolvedConfigRevision == 0 { resolvedConfigRevision = 1 }
        resolvedConfig = TerminalBackendRenderConfigSource.layered(
            base: baseRenderConfig,
            backendDefaults: backendDefaultConfig,
            presentationOverrides: presentationConfigOverrides
        )
        guard canPresent else { return }
        backendPresentationOpen = false
        await rotateReceiver()
        rendererReconfigureNeeded = true
        scheduleDrain()
    }

    private func handleRendererEvent(_ event: TerminalBackendRendererEvent) async {
        switch event {
        case .workerChanged(let changed):
            guard changed.workspaceID.rawValue == currentWorkspaceID else { return }
            await rotateReceiver()
            if changed.state == .ready {
                rendererReconfigureNeeded = true
                scheduleDrain()
            }
        case .presentationReady(let eventPresentationID, let attachment):
            guard eventPresentationID == presentationID else { return }
            do {
                try await installRendererAttachment(attachment)
            } catch {
                await rotateReceiver()
                rendererReconfigureNeeded = true
                scheduleDrain()
            }
        case .connectionLost(let authority):
            guard binding?.authority == authority else { return }
            await rotateReceiver()
            bindingTask?.cancel()
            bindingTask = nil
            binding = nil
            backendPresentationOpen = false
            state = .binding
            replaceSnapshot(lifecycle: .unavailable, clearCellMetrics: true)
            scheduleDrain()
        case .reconnected:
            await rotateReceiver()
            rendererReconfigureNeeded = true
            scheduleDrain()
        }
    }

    private func rotateReceiver() async {
        receiveTask?.cancel()
        receiveTask = nil
        let previous = receiver
        receiver = nil
        if let previous {
            await previous.stop()
        }
        compositor?.removeFromSuperview()
        compositor = nil
        mount?.removeCompositor()
        replaceSnapshot(clearCellMetrics: true)
    }

    private func stopRendererPresentation() async {
        backendPresentationOpen = false
        await rotateReceiver()
    }

    private func detachPresentation() {
        guard !detached else { return }
        if canonicalCloseRequested {
            if case .processExited = state {
                // The close has crossed the daemon boundary; normal detach may finish.
            } else {
                detachAfterCanonicalClose = true
                scheduleDrain()
                return
            }
        }
        detached = true
        drainTask?.cancel()
        drainTask = nil
        bindingTask?.cancel()
        bindingTask = nil
        rendererEventTask?.cancel()
        rendererEventTask = nil
        renderConfigTask?.cancel()
        renderConfigTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        let receiver = receiver
        self.receiver = nil
        if let receiver {
            Task { await receiver.stop() }
        }
        compositor?.removeFromSuperview()
        compositor = nil
        if let mount {
            presentationRegistry.unregister(mount)
        }
        mount = nil
        let client = client
        let presentationID = presentationID
        let binding = binding
        Task {
            await client.detachPresentation(
                presentationID: presentationID,
                from: binding
            )
        }
    }

    private func markUnavailable() {
        state = .unavailable
        queue.removeAll()
        replaceSnapshot(lifecycle: .unavailable)
    }

    private func replaceSnapshot(
        lifecycle: TerminalExternalRuntimeLifecycle? = nil,
        visibleText: String? = nil,
        cellMetrics: TerminalExternalCellMetrics? = nil,
        processMetadata: TerminalExternalProcessMetadata? = nil,
        needsCloseConfirmation: Bool? = nil,
        copyModeActive: Bool? = nil,
        mouseTracking: Bool? = nil,
        copyCursor: TerminalExternalCellPoint? = nil,
        cursor: TerminalExternalCursorState? = nil,
        terminalUXWasRead: Bool = false,
        selection: TerminalExternalSelection? = nil,
        selectionWasRead: Bool = false,
        search: TerminalExternalSearchState? = nil,
        viewportState: TerminalExternalViewportState? = nil,
        clearCellMetrics: Bool = false
    ) {
        snapshot = TerminalExternalRuntimeSnapshot(
            lifecycle: lifecycle ?? snapshot.lifecycle,
            visibleText: visibleText ?? snapshot.visibleText,
            cellMetrics: clearCellMetrics ? nil : (cellMetrics ?? snapshot.cellMetrics),
            processMetadata: processMetadata ?? snapshot.processMetadata,
            needsCloseConfirmation: needsCloseConfirmation ?? snapshot.needsCloseConfirmation,
            copyModeActive: copyModeActive ?? snapshot.copyModeActive,
            mouseTracking: mouseTracking ?? snapshot.mouseTracking,
            copyCursor: terminalUXWasRead ? copyCursor : snapshot.copyCursor,
            cursor: terminalUXWasRead ? cursor : snapshot.cursor,
            selection: selectionWasRead ? selection : snapshot.selection,
            search: search ?? snapshot.search,
            viewportState: viewportState ?? snapshot.viewportState
        )
    }
}
