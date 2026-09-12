@preconcurrency public import Foundation

enum ChromiumNavigationCompletionPredicate {
    static func accepts(
        revisionAdvanced: Bool,
        loading: Bool,
        targetMatches: Bool,
        redirectObserved: Bool
    ) -> Bool {
        revisionAdvanced && !loading && (targetMatches || redirectObserved)
    }
}

extension ChromiumBrowserSession {
    /// Starts a main-frame navigation.
    ///
    /// - Parameter url: Destination URL.
    /// - Throws: A CDP transport error or Chromium navigation rejection.
    public func navigate(to url: URL) async throws {
        if let owlRuntime {
            let baselineDocumentEpoch = owlDocumentEpoch(runtime: owlRuntime)
            beginOwlNavigation(
                .destination(url),
                baselineDocumentEpoch: baselineDocumentEpoch
            )
            do {
                try owlRuntime.navigate(url)
            } catch {
                failOwlNavigation()
                throw error
            }
            startOwlNavigationReadinessMonitor()
            return
        }
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
        if case .object(let object) = result,
           let errorText = object["errorText"]?.stringValue,
           !errorText.isEmpty {
            failNavigation()
            throw CDPError.commandFailed(errorText)
        }
        currentURL = url
        publish()
    }

    /// Traverses to the previous Chromium history entry when one exists.
    ///
    /// - Throws: A CDP transport error or malformed navigation history.
    public func goBack() async throws {
        if let owlRuntime {
            guard let target = owlHistory?.targetURL(offset: -1) else {
                completeOwlNoOpNavigation()
                return
            }
            let baselineDocumentEpoch = owlDocumentEpoch(runtime: owlRuntime)
            beginOwlNavigation(
                .back(target),
                baselineDocumentEpoch: baselineDocumentEpoch
            )
            do {
                _ = try await evaluateJavaScript("history.back()", awaitPromise: false)
            } catch {
                failOwlNavigation()
                throw error
            }
            startOwlNavigationReadinessMonitor()
            return
        }
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
        if let owlRuntime {
            guard let target = owlHistory?.targetURL(offset: 1) else {
                completeOwlNoOpNavigation()
                return
            }
            let baselineDocumentEpoch = owlDocumentEpoch(runtime: owlRuntime)
            beginOwlNavigation(
                .forward(target),
                baselineDocumentEpoch: baselineDocumentEpoch
            )
            do {
                _ = try await evaluateJavaScript("history.forward()", awaitPromise: false)
            } catch {
                failOwlNavigation()
                throw error
            }
            startOwlNavigationReadinessMonitor()
            return
        }
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
        try await reload(ignoreCache: false)
    }

    /// Reloads the active page while bypassing Chromium's HTTP cache.
    ///
    /// - Throws: A CDP transport or command error.
    public func hardReload() async throws {
        try await reload(ignoreCache: true)
    }

    private func reload(ignoreCache: Bool) async throws {
        if let owlRuntime {
            let baselineDocumentEpoch = owlDocumentEpoch(runtime: owlRuntime)
            beginOwlNavigation(
                .reload(currentURL),
                baselineDocumentEpoch: baselineDocumentEpoch
            )
            do {
                // OWL has no cache-control Mojo command. A location reload
                // still exercises the native renderer and preserves the same
                // navigation lifecycle contract; hardReload therefore uses
                // the renderer's ordinary reload semantics on this engine.
                _ = try await evaluateJavaScript("location.reload()", awaitPromise: false)
            } catch {
                failOwlNavigation()
                throw error
            }
            startOwlNavigationReadinessMonitor()
            return
        }
        beginNavigation()
        do {
            _ = try await send(
                method: "Page.reload",
                parameters: .object(["ignoreCache": .bool(ignoreCache)])
            )
        } catch {
            failNavigation()
            throw error
        }
    }

    /// Waits for a main-frame navigation after a known revision. CDP uses its
    /// event stream; OWL uses its ABI readiness monitor when the fork does not
    /// provide a load-complete callback.
    ///
    /// - Parameters:
    ///   - targetURL: Optional requested destination. A completed server redirect
    ///     is accepted only after a navigation event for this operation.
    ///   - revision: Navigation revision captured before issuing the command.
    /// - Throws: Cancellation, renderer failure, or a navigation stream error.
    public func waitForNavigation(
        to targetURL: URL?,
        after revision: UInt64
    ) async throws {
        let targetMatchesCurrent = targetURL.map { matchesCurrentURL($0) } ?? true
        var sawNavigationEvent = navigationRevision > revision
        if ChromiumNavigationCompletionPredicate.accepts(
            revisionAdvanced: navigationRevision > revision,
            loading: isLoading,
            targetMatches: targetMatchesCurrent || owlRedirectCompletionMatches(targetURL: targetURL),
            redirectObserved: sawNavigationEvent
        ) {
            return
        }
        let stream = snapshots()
        for await value in stream {
            try Task.checkCancellation()
            sawNavigationEvent = sawNavigationEvent || value.navigationRevision > revision
            switch value.state {
            case .crashed(let status):
                throw CDPError.disconnected(ChromiumBrowserDiagnostic.rendererExited(status).message)
            case .failed(let message):
                throw CDPError.commandFailed(message)
            default:
                break
            }
            let targetMatchesValue = targetURL.map { Self.matches(url: value.currentURL, target: $0) } ?? true
            if ChromiumNavigationCompletionPredicate.accepts(
                revisionAdvanced: value.navigationRevision > revision,
                loading: value.isLoading,
                targetMatches: targetMatchesValue || owlRedirectCompletionMatches(targetURL: targetURL),
                redirectObserved: sawNavigationEvent
            ) {
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
    /// Cancellation is the caller's deadline mechanism. CDP uses Chromium
    /// lifecycle signals; OWL uses its bounded readiness monitor.
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

    func beginOwlNavigation(
        _ intent: OwlNavigationIntent,
        baselineDocumentEpoch: Double? = nil
    ) {
        owlNavigationIntent = intent
        owlLastRedirectNavigationRevision = nil
        owlLastRedirectNavigationTarget = nil
        owlNavigationSawLoadingEvent = false
        owlNavigationBaselineDocumentEpoch = baselineDocumentEpoch
        isLoading = true
        publish()
    }

    func failOwlNavigation() {
        owlNavigationReadinessTask?.cancel()
        owlNavigationReadinessTask = nil
        owlNavigationIntent = nil
        owlLastRedirectNavigationRevision = nil
        owlLastRedirectNavigationTarget = nil
        owlNavigationSawLoadingEvent = false
        owlNavigationBaselineDocumentEpoch = nil
        failNavigation()
    }

    func completeOwlNoOpNavigation() {
        owlNavigationIntent = nil
        owlLastRedirectNavigationRevision = nil
        owlLastRedirectNavigationTarget = nil
        owlNavigationSawLoadingEvent = false
        owlNavigationBaselineDocumentEpoch = nil
        isLoading = false
        navigationRevision &+= 1
        publish()
    }

    func owlNavigationTargetMatches(
        _ intent: OwlNavigationIntent,
        eventURL: URL?
    ) -> Bool {
        guard let eventURL else { return intent.expectedURL == nil }
        switch intent {
        case .destination, .rendererDestination, .reload:
            // The final document may be a server redirect. The readiness
            // predicate still requires this operation's loading edge and a
            // newer document epoch before accepting the URL.
            return true
        case .back, .forward:
            guard let expectedURL = intent.expectedURL else { return true }
            return Self.matches(url: eventURL, target: expectedURL)
        }
    }

    func commitOwlNavigation(_ intent: OwlNavigationIntent, eventURL: URL?) {
        let committedURL = eventURL ?? intent.expectedURL
        let completedRevision = navigationRevision &+ 1
        switch intent {
        case .destination, .reload:
            owlLastRedirectNavigationRevision = completedRevision
            owlLastRedirectNavigationTarget = intent.expectedURL
        case .rendererDestination, .back, .forward:
            owlLastRedirectNavigationRevision = nil
            owlLastRedirectNavigationTarget = nil
        }
        if let committedURL {
            switch intent {
            case .destination, .rendererDestination:
                owlHistory?.commitDestination(committedURL)
            case .back:
                owlHistory?.commitTraversal(to: committedURL, offset: -1)
            case .forward:
                owlHistory?.commitTraversal(to: committedURL, offset: 1)
            case .reload:
                owlHistory?.commitReload()
            }
            currentURL = committedURL
            syncOwlHistorySnapshot()
        }
        owlNavigationIntent = nil
        owlNavigationSawLoadingEvent = false
        owlNavigationBaselineDocumentEpoch = nil
        isLoading = false
        navigationRevision = completedRevision
        owlNavigationReadinessTask?.cancel()
        owlNavigationReadinessTask = nil
    }

    private func owlRedirectCompletionMatches(targetURL: URL?) -> Bool {
        guard usesNativeOWL(),
              owlLastRedirectNavigationRevision == navigationRevision else {
            return false
        }
        guard let targetURL else { return true }
        guard let requestedURL = owlLastRedirectNavigationTarget else { return false }
        return Self.matches(url: targetURL, target: requestedURL)
    }

    func syncOwlHistorySnapshot() {
        guard let owlHistory else { return }
        canGoBack = owlHistory.canGoBack
        canGoForward = owlHistory.canGoForward
        backHistoryURLs = owlHistory.backURLs
        forwardHistoryURLs = owlHistory.forwardURLs
    }

    /// Starts the readiness fallback for the OWL ABI, whose current release
    /// reports the start edge but has no load-complete callback. The monitor
    /// requires the operation's expected URL and a complete document before it
    /// commits, so stale title updates cannot satisfy automation waits.
    func startOwlNavigationReadinessMonitor() {
        owlNavigationReadinessTask?.cancel()
        guard owlRuntime != nil else { return }
        let generation = lifecycleGeneration
        owlNavigationReadinessTask = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let self else { return }
                let result = await self.readOwlReadiness(generation: generation)
                guard !Task.isCancelled, result else { continue }
                return
            }
        }
    }

    func owlDocumentEpoch(runtime: OwlFreshRuntime) -> Double? {
        guard let raw = try? runtime.evaluate("Number(performance.timeOrigin || 0)"),
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return CDPValue(any: object).doubleValue
    }

    private func owlNavigationDocumentEpochAdvanced(
        _ object: [String: Any]
    ) -> Bool {
        guard let baseline = owlNavigationBaselineDocumentEpoch else {
            return true
        }
        guard let documentEpoch = CDPValue(any: object["documentEpoch"]).doubleValue else {
            return false
        }
        return documentEpoch > baseline + 0.001
    }

    private func readOwlReadiness(generation: UInt64) -> Bool {
        guard lifecycleGeneration == generation,
              let runtime = owlRuntime,
              let intent = owlNavigationIntent else { return true }
        let script = "({href: String(location.href || ''), readyState: String(document.readyState || ''), title: String(document.title || ''), navigationType: String((performance.getEntriesByType('navigation')[0] || {}).type || ''), documentEpoch: Number(performance.timeOrigin || 0)})"
        guard let raw = try? runtime.evaluate(script),
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let href = object["href"] as? String,
              let readyState = object["readyState"] as? String,
              let eventURL = URL(string: href) else {
            return false
        }
        let requiresReloadNavigation: Bool
        if case .reload = intent {
            requiresReloadNavigation = true
        } else {
            requiresReloadNavigation = false
        }
        guard OwlNavigationCompletionPredicate.readinessAccepts(
            sawLoadingEvent: owlNavigationSawLoadingEvent,
            targetMatches: owlNavigationTargetMatches(intent, eventURL: eventURL),
            readyState: readyState,
            documentEpochAdvanced: owlNavigationDocumentEpochAdvanced(object),
            requiresReloadNavigation: requiresReloadNavigation,
            navigationType: object["navigationType"] as? String ?? ""
        ) else {
            return false
        }
        if let documentEpoch = CDPValue(any: object["documentEpoch"]).doubleValue {
            owlCurrentDocumentEpoch = documentEpoch
        }
        if let title = object["title"] as? String, !title.isEmpty { self.title = title }
        commitOwlNavigation(intent, eventURL: eventURL)
        publish()
        return true
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
        if let navigationInterceptor {
            do {
                if try await navigationInterceptor.handle(event, connection: connection) {
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                // A paused request must never remain suspended when the policy
                // bridge fails. Marking the connection crashed closes the
                // transport and fails the navigation closed rather than
                // allowing an unchecked request to continue.
                markCrashed(connection: connection, generation: generation)
                return
            }
        }
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
        case "Runtime.bindingCalled":
            guard let title = documentTitleObservation.title(from: event) else { return }
            self.title = title
            publish()
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
        navigationInterceptor = nil
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
        navigationInterceptor = nil
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
        owlLastRedirectNavigationRevision = nil
        owlLastRedirectNavigationTarget = nil
        // A revision identifies a committed document. Keep it unchanged while
        // the command is in flight so a stale load-complete event cannot look
        // like the new navigation's completion.
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
        navigationInterceptor = nil
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
        if url.absoluteString == target.absoluteString { return true }
        return url.scheme?.caseInsensitiveCompare(target.scheme ?? "") == .orderedSame &&
            url.host?.caseInsensitiveCompare(target.host ?? "") == .orderedSame &&
            Self.effectivePort(for: url) == Self.effectivePort(for: target) &&
            url.user == target.user &&
            url.password == target.password &&
            Self.navigationPath(for: url) == Self.navigationPath(for: target) &&
            url.query == target.query &&
            url.fragment == target.fragment
    }

    /// Returns the URL path in the form Chromium reports for navigation.
    /// Foundation leaves the path empty for an HTTP(S) origin without a
    /// trailing slash, while Chromium reports `/` for that same origin.
    private static func navigationPath(for url: URL) -> String {
        guard url.path.isEmpty else { return url.path }
        switch url.scheme?.lowercased() {
        case "http", "https": return "/"
        default: return url.path
        }
    }

    private static func effectivePort(for url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
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
