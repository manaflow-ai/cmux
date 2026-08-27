@preconcurrency public import Foundation

extension ChromiumBrowserSession {
    /// Starts a main-frame navigation.
    ///
    /// - Parameter url: Destination URL.
    /// - Throws: A CDP transport error or Chromium navigation rejection.
    public func navigate(to url: URL) async throws {
        beginNavigation()
        let result: CDPValue
        do {
            result = try await send(
                method: "Page.navigate",
                parameters: .object(["url": .string(url.absoluteString)])
            )
        } catch {
            failNavigation()
            throw error
        }
        currentURL = url
        if case .object(let object) = result,
           let errorText = object["errorText"]?.stringValue,
           !errorText.isEmpty {
            failNavigation()
            throw CDPError.commandFailed(errorText)
        }
        publish()
    }

    /// Traverses to the previous Chromium history entry when one exists.
    ///
    /// - Throws: A CDP transport error or malformed navigation history.
    public func goBack() async throws {
        beginNavigation()
        do {
            let history = try await navigationHistory(using: connection)
            guard let entryID = history.targetEntryID(offset: -1) else {
                completeNoOpNavigation(history)
                return
            }
            _ = try await send(
                method: "Page.navigateToHistoryEntry",
                parameters: .object(["entryId": .number(Double(entryID))])
            )
        } catch {
            failNavigation()
            throw error
        }
    }

    /// Traverses to the next Chromium history entry when one exists.
    ///
    /// - Throws: A CDP transport error or malformed navigation history.
    public func goForward() async throws {
        beginNavigation()
        do {
            let history = try await navigationHistory(using: connection)
            guard let entryID = history.targetEntryID(offset: 1) else {
                completeNoOpNavigation(history)
                return
            }
            _ = try await send(
                method: "Page.navigateToHistoryEntry",
                parameters: .object(["entryId": .number(Double(entryID))])
            )
        } catch {
            failNavigation()
            throw error
        }
    }

    /// Reloads the active page without bypassing Chromium's cache.
    ///
    /// - Throws: A CDP transport or command error.
    public func reload() async throws {
        beginNavigation()
        do {
            _ = try await send(
                method: "Page.reload",
                parameters: .object(["ignoreCache": .bool(false)])
            )
        } catch {
            failNavigation()
            throw error
        }
    }

    /// Waits for a CDP-reported main-frame navigation after a known revision.
    /// The stream is event-driven; no polling or timing sleeps are used here.
    ///
    /// - Parameters:
    ///   - targetURL: Optional destination that must match the completed page.
    ///   - revision: Navigation revision captured before issuing the command.
    /// - Throws: Cancellation, renderer failure, or a navigation stream error.
    public func waitForNavigation(
        to targetURL: URL?,
        after revision: UInt64
    ) async throws {
        let targetMatchesCurrent = targetURL.map { matchesCurrentURL($0) } ?? true
        if navigationRevision > revision,
           !isLoading,
           targetMatchesCurrent {
            return
        }
        let stream = snapshots()
        for await value in stream {
            try Task.checkCancellation()
            switch value.state {
            case .crashed(let status):
                throw CDPError.disconnected(ChromiumBrowserDiagnostic.rendererExited(status).message)
            case .failed(let message):
                throw CDPError.commandFailed(message)
            default:
                break
            }
            let targetMatchesValue = targetURL.map { Self.matches(url: value.currentURL, target: $0) } ?? true
            if value.navigationRevision > revision,
               !value.isLoading,
               targetMatchesValue {
                return
            }
        }
        throw CDPError.disconnected(ChromiumBrowserDiagnostic.navigationStreamEnded.message)
    }

    /// Returns the current navigation revision for a caller that is about to
    /// issue a navigation command.
    ///
    /// - Returns: The monotonic navigation revision.
    public func currentNavigationRevision() -> UInt64 {
        navigationRevision
    }

    /// Waits until the active page reports that its main frame is ready.
    /// Cancellation is the caller's deadline mechanism; the session itself
    /// uses only Chromium lifecycle signals and never polls or sleeps.
    ///
    /// - Throws: Cancellation, renderer failure, or a navigation stream error.
    public func waitForDocumentReady() async throws {
        let stream = snapshots()
        for await value in stream {
            try Task.checkCancellation()
            switch value.state {
            case .running where !value.isLoading:
                return
            case .crashed(let status):
                throw CDPError.disconnected(ChromiumBrowserDiagnostic.rendererExited(status).message)
            case .failed(let message):
                throw CDPError.commandFailed(message)
            default:
                break
            }
        }
        throw CDPError.disconnected(ChromiumBrowserDiagnostic.navigationStreamEnded.message)
    }

    /// Clears the optimistic loading marker when a navigation command fails
    /// before Chromium emits a terminal frame/load event.
    func failNavigation() {
        isLoading = false
        publish()
    }

    private func navigationHistory(
        using connection: ChromiumCDPConnection?
    ) async throws -> ChromiumNavigationHistory {
        guard let connection else { throw CDPError.notConnected }
        let value = try await connection.send(method: "Page.getNavigationHistory")
        return try ChromiumNavigationHistory(value)
    }

    private func completeNoOpNavigation(_ history: ChromiumNavigationHistory) {
        isLoading = false
        canGoBack = history.canGoBack
        canGoForward = history.canGoForward
        backHistoryURLs = history.backURLs
        forwardHistoryURLs = history.forwardURLs
        publish()
    }

    func handle(
        _ event: CDPEvent,
        connection: ChromiumCDPConnection,
        generation: UInt64
    ) async {
        guard isCurrentConnection(connection, generation: generation) else { return }
        switch event.method {
        case "cmux.cdp.resyncRequired":
            await refreshDocumentState(using: connection, generation: generation)
            publish()
        case "Page.frameNavigated":
            guard let frame = Self.mainFrame(from: event.params),
                  let url = frame["url"]?.stringValue,
                  let parsedURL = URL(string: url) else { return }
            if let frameID = frame["id"]?.stringValue {
                mainFrameID = frameID
            }
            navigationRevision &+= 1
            currentURL = parsedURL
            isLoading = true
            title = frame["title"]?.stringValue
            await refreshNavigationHistory(using: connection)
            await refreshTitle(using: connection)
            publish()
        case "Page.navigatedWithinDocument":
            guard case .object(let object) = event.params,
                  Self.isMainFrame(object: object, knownMainFrameID: mainFrameID),
                  let url = object["url"]?.stringValue,
                  let parsedURL = URL(string: url) else { return }
            // A page-scoped websocket only receives the target's main-frame
            // same-document events. Chromium may omit frameId for the first
            // about:blank target, so there is no stricter filter to apply.
            navigationRevision &+= 1
            currentURL = parsedURL
            isLoading = false
            await refreshNavigationHistory(using: connection)
            await refreshTitle(using: connection)
            publish()
        case "Page.frameStartedLoading":
            if Self.isMainFrame(event.params, knownMainFrameID: mainFrameID) {
                isLoading = true
                publish()
            }
        case "Page.frameStoppedLoading", "Page.loadEventFired":
            guard Self.isMainFrame(event.params, knownMainFrameID: mainFrameID) else { return }
            isLoading = false
            await refreshNavigationHistory(using: connection)
            await refreshTitle(using: connection)
            publish()
        case "Page.lifecycleEvent":
            if case .object(let object) = event.params,
               Self.isMainFrame(object: object, knownMainFrameID: mainFrameID),
               let name = object["name"]?.stringValue,
               ["load", "networkIdle"].contains(name) {
                // DOMContentLoaded and networkAlmostIdle are intermediate
                // milestones. Only the terminal load/networkIdle signals may
                // clear the loading state used by automation waits.
                isLoading = false
                await refreshNavigationHistory(using: connection)
                await refreshTitle(using: connection)
                publish()
            }
        case "Page.crashed", "Target.targetCrashed", "Target.detachedFromTarget", "Inspector.detached":
            markCrashed(connection: connection, generation: generation)
        default:
            break
        }
    }

    /// Re-reads authoritative page state after the bounded CDP event stream
    /// evicts an older notification. This keeps navigation waits truthful
    /// without allowing an unbounded queue to retain every intermediate event.
    private func refreshDocumentState(
        using connection: ChromiumCDPConnection,
        generation: UInt64
    ) async {
        guard isCurrentConnection(connection, generation: generation) else { return }
        let wasLoading = isLoading
        if let value = try? await connection.send(method: "Page.getFrameTree"),
           isCurrentConnection(connection, generation: generation),
           case .object(let root) = value,
           case .object(let frameTree)? = root["frameTree"],
           case .object(let frame)? = frameTree["frame"] {
            if let frameID = frame["id"]?.stringValue {
                mainFrameID = frameID
            }
            if let rawURL = frame["url"]?.stringValue,
               let url = URL(string: rawURL) {
                if currentURL != url {
                    navigationRevision &+= 1
                }
                currentURL = url
            }
        }
        guard isCurrentConnection(connection, generation: generation) else { return }
        await refreshNavigationHistory(using: connection)
        await refreshTitle(using: connection)
        guard isCurrentConnection(connection, generation: generation) else { return }
        let readinessValue = try? await connection.send(
            method: "Runtime.evaluate",
            parameters: .object([
                "expression": .string("document.readyState"),
                "returnByValue": .bool(true),
            ])
        )
        guard isCurrentConnection(connection, generation: generation) else { return }
        if case .object(let object)? = readinessValue,
           case .object(let result)? = object["result"],
           let readyState = result["value"]?.stringValue {
            isLoading = readyState != "complete"
        } else {
            // A missing readiness response is not proof of completion; retain
            // the state observed before the resync began.
            isLoading = wasLoading
        }
    }

    func connectionEnded(connection endedConnection: ChromiumCDPConnection, generation: UInt64) {
        guard isCurrentConnection(endedConnection, generation: generation), !isStopping else { return }
        self.connection = nil
        connectionGeneration = nil
        screencastUpdateTask?.cancel()
        screencastUpdateTask = nil
        isScreencastActive = false
        endedConnection.close()
        let processToTerminate = process
        state = .crashed(-1)
        isLoading = false
        mainFrameID = nil
        backHistoryURLs.removeAll(keepingCapacity: false)
        forwardHistoryURLs.removeAll(keepingCapacity: false)
        processToTerminate?.terminate()
        publish()
    }

    func markCrashed(
        connection crashedConnection: ChromiumCDPConnection,
        generation: UInt64
    ) {
        guard isCurrentConnection(crashedConnection, generation: generation), !isStopping else { return }
        state = .crashed(-1)
        isLoading = false
        mainFrameID = nil
        backHistoryURLs.removeAll(keepingCapacity: false)
        forwardHistoryURLs.removeAll(keepingCapacity: false)
        connection = nil
        connectionGeneration = nil
        screencastUpdateTask?.cancel()
        screencastUpdateTask = nil
        isScreencastActive = false
        crashedConnection.close()
        let processToTerminate = process
        processToTerminate?.terminate()
        eventTask?.cancel()
        eventTask = nil
        frameForwardTask?.cancel()
        frameForwardTask = nil
        publish()
    }

    func isCurrentStartup(_ generation: UInt64) -> Bool {
        startupGeneration == generation && lifecycleGeneration == generation && !isStopping
    }

    func isCurrentConnection(
        _ candidate: ChromiumCDPConnection,
        generation: UInt64? = nil
    ) -> Bool {
        guard let current = connection, current === candidate else { return false }
        if let generation {
            return connectionGeneration == generation && lifecycleGeneration == generation
        }
        return true
    }

    func beginNavigation() {
        navigationRevision &+= 1
        isLoading = true
        publish()
    }

    func refreshNavigationHistory(using connection: ChromiumCDPConnection) async {
        guard isCurrentConnection(connection),
              let value = try? await connection.send(method: "Page.getNavigationHistory"),
              isCurrentConnection(connection),
              let history = try? ChromiumNavigationHistory(value) else { return }
        canGoBack = history.canGoBack
        canGoForward = history.canGoForward
        backHistoryURLs = history.backURLs
        forwardHistoryURLs = history.forwardURLs
    }

    func refreshTitle(using connection: ChromiumCDPConnection) async {
        guard isCurrentConnection(connection),
              let value = try? await connection.send(
            method: "Runtime.evaluate",
            parameters: .object([
                "expression": .string("document.title"),
                "returnByValue": .bool(true),
            ])
        ), isCurrentConnection(connection), case .object(let object) = value,
              case .object(let result)? = object["result"] else { return }
        title = result["value"]?.stringValue ?? ""
    }

    func cleanupAfterStartFailure(
        _ error: any Error,
        generation: UInt64,
        launchedProcess: Process?,
        establishedConnection: ChromiumCDPConnection?
    ) {
        guard lifecycleGeneration == generation else {
            establishedConnection?.close()
            launchedProcess?.terminate()
            return
        }
        establishedConnection?.close()
        let currentProcess = process
        process = nil
        currentProcess?.terminate()
        if let launchedProcess {
            if let currentProcess {
                if currentProcess !== launchedProcess {
                    launchedProcess.terminate()
                }
            } else {
                launchedProcess.terminate()
            }
        }
        connection = nil
        connectionGeneration = nil
        eventTask?.cancel()
        eventTask = nil
        frameForwardTask?.cancel()
        frameForwardTask = nil
        screencastUpdateTask?.cancel()
        screencastUpdateTask = nil
        isScreencastActive = false
        internalPort = nil
        mainFrameID = nil
        isLoading = false
        backHistoryURLs.removeAll(keepingCapacity: false)
        forwardHistoryURLs.removeAll(keepingCapacity: false)
        state = error is CancellationError || isStopping
            ? .stopped
            : .failed(ChromiumBrowserDiagnostic.startupFailed.message)
        publish()
    }

    func matchesCurrentURL(_ target: URL) -> Bool {
        Self.matches(url: currentURL, target: target)
    }

    static func matches(url: URL?, target: URL) -> Bool {
        guard let url else { return false }
        return url.absoluteString == target.absoluteString ||
            (url.scheme == target.scheme && url.host == target.host && url.path == target.path && url.query == target.query)
    }

    private static func mainFrame(from params: CDPValue?) -> [String: CDPValue]? {
        guard case .object(let object) = params,
              let frame = object["frame"],
              case .object(let frameObject) = frame,
              frameObject["parentId"] == nil else { return nil }
        return frameObject
    }

    private static func isMainFrame(
        _ params: CDPValue?,
        knownMainFrameID: String?
    ) -> Bool {
        guard case .object(let object) = params else { return true }
        return isMainFrame(object: object, knownMainFrameID: knownMainFrameID)
    }

    private static func isMainFrame(
        object: [String: CDPValue],
        knownMainFrameID: String?
    ) -> Bool {
        guard let frameID = object["frameId"]?.stringValue else {
            // Older headless-shell revisions omit frameId from
            // Page.loadEventFired. That event is page-scoped, so it is safe to
            // accept only when there is no contradictory known frame id.
            return true
        }
        guard let knownMainFrameID else {
            // Before Page.getFrameTree has completed, accepting the first
            // non-empty frame id keeps startup loading visible. Subsequent
            // events are filtered against the recorded top-level id.
            return !frameID.isEmpty
        }
        return frameID == knownMainFrameID
    }
}
