import Foundation

/// A bounded in-process bridge from ``CmuxEventBus`` to configured actions.
///
/// The engine is main-actor owned because notification delivery and the v2
/// dispatcher are main-actor domains. Event consumption itself happens on a
/// utility task and only schedules small, ordered decisions back to this
/// owner. No event-log tailer is involved.
@MainActor
final class AutomationEngine {
    typealias NotificationHandler = @MainActor (UUID, UUID?, String, String, String) -> Void
    typealias RPCRunner = @Sendable (String, [String: Any], Bool, CmuxAutomationEventOrigin) async -> String
    typealias RecoverySleeper = @Sendable (Duration) async throws -> Void
    typealias ProcessRunner = @Sendable (String, [String: String]) async -> AutomationActionExecutionResult
    typealias WebhookRunner = @Sendable (URL, [String: String], Data) async -> AutomationActionExecutionResult
    typealias WorkspaceTagsResolver = @MainActor (UUID) -> [String]

    private static let maximumLogRecords = 256
    private static let maximumChainDepth = 16
    private static let maximumConcurrentFirings = 32
    private static let defaultRateLimit = AutomationRateLimit(intervalSeconds: 1, maximum: 1)
    private static let subscriptionControlEventNames: Set<String> = [
        "config.reloaded",
        "sidebar.metadata.updated",
        "sidebar.metadata.cleared",
        "sidebar.reset",
        "workspace.created",
        "workspace.closed",
        "workspace.renamed"
    ]

    private let configStore: AutomationConfigStore
    private let eventBus: CmuxEventBus
    private let notificationHandler: NotificationHandler
    private let rpcRunner: RPCRunner
    private let processRunner: ProcessRunner?
    private let webhookRunner: WebhookRunner?
    private let workspaceTagsResolver: WorkspaceTagsResolver
    private let payloadRedactor = AutomationPayloadRedactor()
    private let recoverySleeper: RecoverySleeper

    private var rules: [AutomationRule] = []
    private var rulesByEventName: [String: [AutomationRule]] = [:]
    private var rulesByCategory: [String: [AutomationRule]] = [:]
    private var unindexedRules: [AutomationRule] = []
    private var fireDatesByRuleID: [String: [Date]] = [:]
    private var firingRecords: [AutomationFiringRecord] = []
    private var concurrentFirings = 0
    private var subscription: CmuxEventSubscription?
    private var eventTask: Task<Void, Never>?
    private var firingTasks: [UUID: Task<Void, Never>] = [:]
    private var shouldRun = false
    private var workspaceTagsCache: [UUID: [String]] = [:]
    private var pendingTagResolutions = Set<UUID>()
    private var lastSequence: Int64?
    private var restartTask: Task<Void, Never>?
    private var restartAttempt = 0
    private var reloadTask: Task<Void, Never>?
    private var reloadRequestedWhileLoading = false
    private var enabledUpdateTasks: [String: (requestID: UUID, task: Task<Void, Never>)] = [:]
    private var enabledUpdateRequestIDs: [String: UUID] = [:]

    init(
        configStore: AutomationConfigStore = AutomationConfigStore(),
        eventBus: CmuxEventBus = .shared,
        notificationHandler: @escaping NotificationHandler = { workspaceID, surfaceID, title, subtitle, body in
            TerminalController.shared.deliverNotificationSynchronously(
                tabId: workspaceID,
                surfaceId: surfaceID,
                title: title,
                subtitle: subtitle,
                body: body,
                retargetsToLiveSurfaceOwner: true
            )
        },
        rpcRunner: @escaping RPCRunner = { method, params, allowFocus, origin in
            await TerminalController.shared.performAutomationRPC(
                method: method,
                params: params,
                allowFocus: allowFocus,
                origin: origin
            )
        },
        processRunner: ProcessRunner? = nil,
        webhookRunner: WebhookRunner? = nil,
        workspaceTagsResolver: @escaping WorkspaceTagsResolver = { _ in [] },
        recoverySleeper: @escaping RecoverySleeper = { duration in
            try await ContinuousClock().sleep(for: duration)
        }
    ) {
        self.configStore = configStore
        self.eventBus = eventBus
        self.notificationHandler = notificationHandler
        self.rpcRunner = rpcRunner
        self.processRunner = processRunner
        self.webhookRunner = webhookRunner
        self.workspaceTagsResolver = workspaceTagsResolver
        self.recoverySleeper = recoverySleeper
    }

    deinit {
        if let subscription {
            eventBus.unsubscribe(subscription)
        }
        eventTask?.cancel()
        restartTask?.cancel()
        reloadTask?.cancel()
        firingTasks.values.forEach { $0.cancel() }
        enabledUpdateTasks.values.forEach { $0.task.cancel() }
    }

    /// Starts the live subscription. Calling this more than once is harmless.
    func start() {
        shouldRun = true
        guard eventTask == nil else { return }
        scheduleReload()
    }

    private func installSubscription(afterSequence: Int64?) {
        guard shouldRun else { return }
        restartTask?.cancel()
        restartTask = nil
        let effectiveAfterSequence = afterSequence ?? eventBus.latestSequence
        let filters = subscriptionFilters()
        let snapshot = eventBus.subscribe(
            afterSequence: effectiveAfterSequence,
            names: filters.names,
            categories: filters.categories
        )
        subscription = snapshot.subscription
        let subscription = snapshot.subscription
        lastSequence = max(lastSequence ?? effectiveAfterSequence, effectiveAfterSequence)
        if let resume = snapshot.ack["resume"] as? [String: Any],
           (resume["gap"] as? Bool) == true {
            record(
                ruleID: "",
                eventName: "automation.subscription",
                status: "gap",
                detail: "event replay began after the retained sequence window",
                chain: []
            )
        }
        for event in snapshot.replay {
            receive(event)
        }
        eventTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let event = await subscription.nextAsync(),
                      let eventData = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) else {
                    if subscription.isClosed { break }
                    continue
                }
                await MainActor.run { [weak self] in
                    self?.receive(serializedEvent: eventData)
                }
            }
            await MainActor.run { [weak self] in
                self?.subscriptionDidClose(subscription)
            }
        }
    }

    private func subscriptionDidClose(_ closedSubscription: CmuxEventSubscription) {
        guard subscription === closedSubscription else { return }
        eventBus.unsubscribe(closedSubscription)
        subscription = nil
        eventTask = nil
        guard shouldRun else { return }
        // A slow consumer closes its bounded queue. Re-arm from the last
        // processed sequence with one coalesced, cancellable retry.
        // The bounded clock delay prevents a sustained flood from spinning the
        // main actor while preserving automatic recovery.
        guard restartTask == nil else { return }
        let delayMilliseconds = min(5_000, 250 * (1 << min(restartAttempt, 5)))
        restartAttempt = min(restartAttempt + 1, 5)
        let sleeper = recoverySleeper
        restartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await sleeper(.milliseconds(delayMilliseconds))
            } catch {
                return
            }
            self.restartTask = nil
            guard self.shouldRun else { return }
            let resumeSequence = self.lastSequence ?? self.eventBus.latestSequence
            self.installSubscription(afterSequence: resumeSequence)
        }
    }

    /// Stops the live subscription and wakes a blocked event read.
    func stop() {
        shouldRun = false
        restartTask?.cancel()
        restartTask = nil
        reloadTask?.cancel()
        reloadTask = nil
        reloadRequestedWhileLoading = false
        subscription?.close()
        if let subscription {
            eventBus.unsubscribe(subscription)
        }
        subscription = nil
        eventTask?.cancel()
        eventTask = nil
        firingTasks.values.forEach { $0.cancel() }
        enabledUpdateTasks.values.forEach { $0.task.cancel() }
        enabledUpdateTasks.removeAll(keepingCapacity: true)
        enabledUpdateRequestIDs.removeAll(keepingCapacity: true)
        workspaceTagsCache.removeAll(keepingCapacity: true)
        pendingTagResolutions.removeAll(keepingCapacity: true)
    }

    /// Reloads the file and returns a compact command response.
    func scheduleReload() {
        guard reloadTask == nil else {
            reloadRequestedWhileLoading = true
            return
        }
        reloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.reloadAsync()
            self.reloadTask = nil
            if self.reloadRequestedWhileLoading {
                self.reloadRequestedWhileLoading = false
                self.scheduleReload()
            }
        }
    }

    func reloadAsync() async -> Result<Int, Error> {
        do {
            let configuration = try await configStore.loadOffMain()
            guard !Task.isCancelled else { return .failure(CancellationError()) }
            apply(configuration)
            if shouldRun {
                if let subscription {
                    eventBus.unsubscribe(subscription)
                    subscription.close()
                    self.subscription = nil
                }
                eventTask?.cancel()
                eventTask = nil
                // A rule-set change is not a reconnect: never replay events
                // that arrived while the previous snapshot was active.
                installSubscription(afterSequence: nil)
            }
            return .success(rules.count)
        } catch {
            clearActiveRules()
            // Keep a control-only subscription alive so a later
            // config.reloaded event can recover from an invalid file without
            // requiring an application restart.
            if shouldRun {
                installSubscription(afterSequence: eventBus.latestSequence)
            }
            record(
                ruleID: "",
                eventName: "config.reload",
                status: "error",
                detail: String(describing: error),
                chain: []
            )
            return .failure(error)
        }
    }

    private func apply(_ configuration: AutomationConfiguration) {
        rules = configuration.rules
        rebuildRuleIndexes()
        fireDatesByRuleID.removeAll(keepingCapacity: true)
        workspaceTagsCache.removeAll(keepingCapacity: true)
        pendingTagResolutions.removeAll(keepingCapacity: true)
    }

    private func clearActiveRules() {
        rules.removeAll(keepingCapacity: true)
        rulesByEventName.removeAll(keepingCapacity: true)
        rulesByCategory.removeAll(keepingCapacity: true)
        unindexedRules.removeAll(keepingCapacity: true)
        fireDatesByRuleID.removeAll(keepingCapacity: true)
        // Keep the firing reservation count until canceled tasks run their
        // deferred release; resetting it here could admit new actions while
        // old shells/webhooks are still unwinding.
        firingTasks.values.forEach { $0.cancel() }
        workspaceTagsCache.removeAll(keepingCapacity: true)
        pendingTagResolutions.removeAll(keepingCapacity: true)
        if let subscription {
            eventBus.unsubscribe(subscription)
            subscription.close()
            self.subscription = nil
        }
        eventTask?.cancel()
        eventTask = nil
        restartTask?.cancel()
        restartTask = nil
    }

    private func rebuildRuleIndexes() {
        rulesByEventName.removeAll(keepingCapacity: true)
        rulesByCategory.removeAll(keepingCapacity: true)
        unindexedRules.removeAll(keepingCapacity: true)
        for rule in rules {
            let exactEvent = rule.when.event.flatMap { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty || trimmed.contains("*") ? nil : trimmed
            }
            let exactCategory = rule.when.category.flatMap { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty || trimmed.contains("*") ? nil : trimmed
            }
            if let exactEvent, rule.when.category == nil {
                rulesByEventName[AutomationRule.caseInsensitiveMatchKey(exactEvent), default: []].append(rule)
            } else if let exactCategory, rule.when.event == nil {
                rulesByCategory[AutomationRule.caseInsensitiveMatchKey(exactCategory), default: []].append(rule)
            } else {
                unindexedRules.append(rule)
            }
        }
    }

    private func subscriptionFilters() -> (names: Set<String>, categories: Set<String>) {
        let enabledRules = rules.filter(\.enabled)
        guard !enabledRules.isEmpty else {
            return (Self.subscriptionControlEventNames, [])
        }
        // Selector matching is intentionally case-insensitive, while the
        // event bus's name/category filters are exact. Keep this subscription
        // unfiltered so a case variant can never be rejected before matching,
        // and so engine-control/invalidation events are always observed.
        return ([], [])
    }

    func listPayload() -> [[String: Any]] {
        rules.map { rule in
            [
                "id": rule.id,
                "enabled": rule.enabled,
                "event": rule.when.event ?? NSNull(),
                "category": rule.when.category ?? NSNull(),
                "action_count": rule.actions.count,
                "rate_limit": Self.rateLimitPayload(rule.rateLimit ?? Self.defaultRateLimit)
            ]
        }
    }

    func rule(withID id: String) -> AutomationRule? {
        rules.first(where: { $0.id == id })
    }

    func showPayload(id: String) -> [String: Any]? {
        guard let rule = rule(withID: id),
              let data = try? JSONEncoder().encode(payloadRedactor.rule(rule)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    func scheduleSetEnabled(id: String, enabled: Bool) -> Bool {
        guard rules.contains(where: { $0.id == id }) else { return false }
        enabledUpdateTasks[id]?.task.cancel()
        let requestID = UUID()
        enabledUpdateRequestIDs[id] = requestID
        let task = Task { @MainActor [weak self] in
            defer {
                if let self, self.enabledUpdateRequestIDs[id] == requestID {
                    self.enabledUpdateRequestIDs.removeValue(forKey: id)
                    self.enabledUpdateTasks.removeValue(forKey: id)
                }
            }
            guard let self else { return }
            guard !Task.isCancelled else { return }
            let result = await self.setEnabled(
                id: id,
                enabled: enabled,
                requestID: requestID
            )
            switch result {
            case .success:
                self.record(
                    ruleID: id,
                    eventName: enabled ? "config.enable" : "config.disable",
                    status: "completed",
                    detail: enabled ? "rule enabled" : "rule disabled",
                    chain: []
                )
            case .failure(let error) where error is CancellationError:
                break
            case .failure(let error):
                self.record(
                    ruleID: id,
                    eventName: enabled ? "config.enable" : "config.disable",
                    status: "error",
                    detail: String(describing: error),
                    chain: []
                )
            }
        }
        enabledUpdateTasks[id] = (requestID: requestID, task: task)
        return true
    }

    func setEnabled(id: String, enabled: Bool) async -> Result<AutomationRule, Error> {
        await setEnabled(id: id, enabled: enabled, requestID: nil)
    }

    private func setEnabled(
        id: String,
        enabled: Bool,
        requestID: UUID?
    ) async -> Result<AutomationRule, Error> {
        do {
            let rule = try await configStore.updateRuleOffMain(id: id) { rule in
                rule.enabled = enabled
            }
            if let requestID,
               enabledUpdateRequestIDs[id] != requestID {
                return .failure(CancellationError())
            }
            if let index = rules.firstIndex(where: { $0.id == id }) {
                rules[index] = rule
            }
            rebuildRuleIndexes()
            if shouldRun {
                if let subscription {
                    eventBus.unsubscribe(subscription)
                    subscription.close()
                    self.subscription = nil
                }
                eventTask?.cancel()
                eventTask = nil
                // Enabling/disabling a rule changes the action snapshot; start
                // at the current tail instead of replaying historical events.
                installSubscription(afterSequence: nil)
            }
            return .success(rule)
        } catch {
            return .failure(error)
        }
    }

    /// Evaluates one synthetic event without consuming rate-limit state or
    /// executing any action. This is the same matcher used by the live path.
    func testPayload(id: String, event: [String: Any]) -> [String: Any]? {
        guard let rule = rule(withID: id) else { return nil }
        let normalized = Self.normalizedEvent(event)
        let tags = rule.usesWorkspaceTagPredicate
            ? workspaceTags(for: normalized, allowOwnerResolution: true)
            : []
        let matches = rule.matches(event: normalized, workspaceTags: tags)
        return [
            "id": rule.id,
            "enabled": rule.enabled,
            "matched": matches,
            "event": payloadRedactor.event(normalized),
            "actions": rule.actions.map(payloadRedactor.actionPayload),
            "dry_run": true,
            "reason": matches ? "matched" : "predicate_mismatch"
        ]
    }

    func logsPayload(limit: Int = 100) -> [[String: Any]] {
        let boundedLimit = min(max(1, limit), Self.maximumLogRecords)
        return firingRecords.suffix(boundedLimit).map(\.payload)
    }

    private func receive(_ event: [String: Any]) {
        guard (event["type"] as? String ?? "event") == "event",
              let eventName = event["name"] as? String else {
            return
        }
        let normalized = Self.normalizedEvent(event)
        if let sequence = CmuxEventBus.int64(normalized["seq"]) {
            lastSequence = max(lastSequence ?? sequence, sequence)
        }
        if eventName == "config.reloaded" {
            scheduleReload()
        }
        let invalidatesWorkspaceTags =
            ["sidebar.metadata.updated", "sidebar.metadata.cleared", "sidebar.reset"].contains(eventName)
                || ["workspace.created", "workspace.closed", "workspace.renamed"].contains(eventName)
        if invalidatesWorkspaceTags {
            if let workspaceID = Self.uuid(event["workspace_id"] as? String) {
                workspaceTagsCache.removeValue(forKey: workspaceID)
            } else {
                workspaceTagsCache.removeAll(keepingCapacity: true)
            }
        }
        let origin = Self.origin(from: normalized)
        let candidateRules = candidateRules(
            eventName: eventName,
            category: normalized["category"] as? String
        )
        let tags = candidateRules.contains(where: { $0.enabled && $0.usesWorkspaceTagPredicate })
            ? workspaceTags(for: normalized, allowOwnerResolution: true)
            : []
        for rule in candidateRules where rule.enabled {
            guard rule.matches(event: normalized, workspaceTags: tags) else { continue }
            if let origin, origin.chain.contains(rule.id) {
                record(
                    ruleID: rule.id,
                    eventName: eventName,
                    status: "skipped_loop",
                    detail: "rule already appears in automation origin chain",
                    chain: origin.chain
                )
                continue
            }
            if let origin, origin.chain.count >= Self.maximumChainDepth {
                record(
                    ruleID: rule.id,
                    eventName: eventName,
                    status: "skipped_loop",
                    detail: "automation origin chain exceeded depth limit",
                    chain: origin.chain
                )
                continue
            }
            guard concurrentFirings < Self.maximumConcurrentFirings else {
                record(
                    ruleID: rule.id,
                    eventName: eventName,
                    status: "skipped_backpressure",
                    detail: "automation firing concurrency limit exceeded",
                    chain: origin?.chain ?? []
                )
                continue
            }
            guard admit(rule: rule) else {
                record(
                    ruleID: rule.id,
                    eventName: eventName,
                    status: "skipped_rate_limit",
                    detail: "per-rule rate limit exceeded",
                    chain: origin?.chain ?? []
                )
                continue
            }

            let chain = (origin?.chain ?? []) + [rule.id]
            record(
                ruleID: rule.id,
                eventName: eventName,
                status: "started",
                detail: "rule matched",
                chain: chain
            )
            concurrentFirings += 1
            let firingID = UUID()
            let firingTask = Task { @MainActor [weak self] in
                defer {
                    self?.concurrentFirings = max(0, (self?.concurrentFirings ?? 1) - 1)
                    self?.firingTasks.removeValue(forKey: firingID)
                }
                guard !Task.isCancelled else { return }
                await self?.execute(rule: rule, event: normalized, chain: chain)
            }
            firingTasks[firingID] = firingTask
        }
    }

    private func receive(serializedEvent data: Data) {
        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        receive(event)
    }

    private func candidateRules(eventName: String, category: String?) -> [AutomationRule] {
        var candidates = unindexedRules
        candidates.append(contentsOf: rulesByEventName[AutomationRule.caseInsensitiveMatchKey(eventName)] ?? [])
        if let category {
            candidates.append(contentsOf: rulesByCategory[AutomationRule.caseInsensitiveMatchKey(category)] ?? [])
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.id).inserted }
    }

    private func admit(rule: AutomationRule) -> Bool {
        let limit = rule.rateLimit ?? Self.defaultRateLimit
        let now = Date()
        let cutoff = now.addingTimeInterval(-limit.intervalSeconds)
        var dates = fireDatesByRuleID[rule.id, default: []].filter { $0 >= cutoff }
        guard dates.count < limit.maximum else {
            fireDatesByRuleID[rule.id] = dates
            return false
        }
        dates.append(now)
        fireDatesByRuleID[rule.id] = dates
        return true
    }

    private func execute(rule: AutomationRule, event: [String: Any], chain: [String]) async {
        var failure: String?
        for action in rule.actions {
            guard !Task.isCancelled else { return }
            let result = await execute(action: action, rule: rule, event: event, chain: chain)
            guard result.succeeded else {
                failure = result.detail
                break
            }
        }
        record(
            ruleID: rule.id,
            eventName: event["name"] as? String ?? "",
            status: failure == nil ? "completed" : "error",
            detail: failure ?? "all actions completed",
            chain: chain
        )
    }

    private func execute(
        action: AutomationAction,
        rule: AutomationRule,
        event: [String: Any],
        chain: [String]
    ) async -> AutomationActionExecutionResult {
        switch action.action.lowercased() {
        case "notify":
            return executeNotify(action: action, rule: rule, event: event, chain: chain)
        case "rpc":
            return await executeRPC(action: action, rule: rule, event: event, chain: chain)
        case "run":
            return await executeRun(action: action, rule: rule, event: event, chain: chain)
        case "webhook":
            return await executeWebhook(action: action, rule: rule, event: event, chain: chain)
        default:
            return .failure("unknown automation action \(action.action)")
        }
    }

    private func executeNotify(
        action: AutomationAction,
        rule: AutomationRule,
        event: [String: Any],
        chain: [String]
    ) -> AutomationActionExecutionResult {
        let workspaceID = Self.uuid(
            action.string(for: "workspace_id")
                ?? action.string(for: "workspace")
                ?? event["workspace_id"] as? String
        )
        guard let workspaceID else {
            return .failure("notify action could not resolve a workspace")
        }
        let surfaceID = Self.uuid(
            action.string(for: "surface_id")
                ?? action.string(for: "surface")
                ?? event["surface_id"] as? String
        )
        let title = render(action.string(for: "title") ?? "Automation: \(rule.id)", event: event)
        let subtitle = render(action.string(for: "subtitle") ?? "", event: event)
        let body = render(
            action.string(for: "body") ?? action.string(for: "message") ?? (event["name"] as? String ?? "Automation fired"),
            event: event
        )
        let origin = CmuxAutomationEventOrigin(ruleID: rule.id, chain: chain)
        CmuxAutomationInvocationContext.$eventOrigin.withValue(origin) {
            notificationHandler(workspaceID, surfaceID, title, subtitle, body)
        }
        return .success("notification delivered")
    }

    private func executeRPC(
        action: AutomationAction,
        rule: AutomationRule,
        event: [String: Any],
        chain: [String]
    ) async -> AutomationActionExecutionResult {
        guard let method = action.string(for: "method"), !method.isEmpty else {
            return .failure("rpc action is missing method")
        }
        let params = action.object(for: "params")?.mapValues(\.foundationObject) ?? [:]
        let nestedFocus = action.object(for: "params")?["focus"]?.boolValue
        let allowFocus = action.bool(for: "allow_focus")
            ?? action.bool(for: "focus")
            ?? nestedFocus
            ?? false
        let origin = CmuxAutomationEventOrigin(ruleID: rule.id, chain: chain)
        let response = await rpcRunner(method, params, allowFocus, origin)
        if response.hasPrefix("ERROR:") {
            return .failure(response)
        }
        guard let data = response.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .success("rpc completed")
        }
        if let ok = object["ok"] as? Bool, !ok {
            let error = object["error"] as? [String: Any]
            return .failure(error?["message"] as? String ?? "rpc action failed")
        }
        return .success("rpc completed")
    }

    private func executeRun(
        action: AutomationAction,
        rule: AutomationRule,
        event: [String: Any],
        chain: [String]
    ) async -> AutomationActionExecutionResult {
        guard let command = action.string(for: "command") ?? action.string(for: "cmd"), !command.isEmpty else {
            return .failure("run action is missing command")
        }
        guard let eventLine = Self.eventJSON(event) else {
            return .failure("could not serialize automation event")
        }
        var environment = [
            "CMUX_AUTOMATION_EVENT": eventLine,
            "CMUX_AUTOMATION_EVENT_JSON": eventLine,
            "CMUX_EVENT_JSON": eventLine,
            "CMUX_AUTOMATION_RULE_ID": rule.id,
            "CMUX_AUTOMATION_CHAIN": Self.encodedChain(chain),
            "CMUX_AUTOMATION_EVENT_NAME": event["name"] as? String ?? "",
            "CMUX_AUTOMATION_EVENT_CATEGORY": event["category"] as? String ?? ""
        ]
        if let source = event["source"] as? String { environment["CMUX_AUTOMATION_SOURCE"] = source }
        let timeoutSeconds = min(
            300,
            max(0.1, action.double(for: "timeout_seconds") ?? 60)
        )
        if let processRunner {
            return await processRunner(command, environment)
        }
        return await runProcess(
            command: command,
            environment: environment,
            timeoutSeconds: timeoutSeconds
        )
    }

    private func executeWebhook(
        action: AutomationAction,
        rule: AutomationRule,
        event: [String: Any],
        chain: [String]
    ) async -> AutomationActionExecutionResult {
        let configuredHeaders = action.object(for: "headers")?.reduce(into: [String: String]()) { result, entry in
            if let value = entry.value.stringValue { result[entry.key] = value }
        } ?? [:]
        guard let rawURL = action.string(for: "url"),
              let url = URL(string: rawURL),
              AutomationWebhookPolicy().isValid(url: url, headers: configuredHeaders) else {
            return .failure("webhook action requires an http(s) url")
        }
        guard let data = Self.eventJSONData(event) else {
            return .failure("could not serialize automation event")
        }
        var headers: [String: String] = ["Content-Type": "application/json"]
        for (key, value) in configuredHeaders.prefix(64) {
            headers[String(key.prefix(256))] = String(value.prefix(8_192))
        }
        if let webhookRunner {
            return await webhookRunner(url, headers, data)
        }
        return await runWebhook(url: url, headers: headers, data: data)
    }

#if compiler(>=6.2)
    @concurrent
#else
    @Sendable
#endif
    nonisolated private func runProcess(
        command: String,
        environment: [String: String],
        timeoutSeconds: TimeInterval
    ) async -> AutomationActionExecutionResult {
        let session = AutomationProcessSession(
            command: command,
            environment: environment
        )
        return await withTaskCancellationHandler(operation: {
            await session.run(timeoutSeconds: timeoutSeconds)
        }, onCancel: {
            session.cancel()
        })
    }

#if compiler(>=6.2)
    @concurrent
#else
    @Sendable
#endif
    nonisolated private func runWebhook(
        url: URL,
        headers: [String: String],
        data: Data
    ) async -> AutomationActionExecutionResult {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.timeoutInterval = 15
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let webhookPolicy = AutomationWebhookPolicy()
        let redirectDelegate = AutomationWebhookRedirectDelegate(
            originalURL: url,
            sensitiveHeaderNames: webhookPolicy.credentialHeaderNames(in: headers)
        )
        let sessionWithDelegate = URLSession(
            configuration: {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 15
                configuration.timeoutIntervalForResource = 20
                configuration.httpShouldSetCookies = false
                configuration.httpCookieStorage = nil
                configuration.urlCache = nil
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                return configuration
            }(),
            delegate: redirectDelegate,
            delegateQueue: nil
        )
        defer { sessionWithDelegate.invalidateAndCancel() }
        do {
            let (bytes, response) = try await sessionWithDelegate.bytes(for: request)
            guard let response = response as? HTTPURLResponse else {
                return .failure("webhook returned a non-HTTP response")
            }
            guard (200..<300).contains(response.statusCode) else {
                return .failure("webhook returned HTTP \(response.statusCode)")
            }
            var responseBytes = 0
            for try await _ in bytes {
                responseBytes += 1
                if responseBytes > 64 * 1_024 {
                    return .failure("webhook response exceeded 64 KiB")
                }
            }
            return .success("webhook delivered")
        } catch {
            return .failure("webhook failed: \(error.localizedDescription)")
        }
    }

    private func workspaceTags(
        for event: [String: Any],
        allowOwnerResolution: Bool = false
    ) -> [String] {
        guard let workspaceID = Self.uuid(event["workspace_id"] as? String) else { return [] }
        if let cached = workspaceTagsCache[workspaceID] {
            return cached
        }
        guard allowOwnerResolution else { return [] }
        guard pendingTagResolutions.insert(workspaceID).inserted else { return [] }
        defer { pendingTagResolutions.remove(workspaceID) }
        let resolved = workspaceTagsResolver(workspaceID)
        workspaceTagsCache[workspaceID] = resolved
        return resolved
    }

    private func record(ruleID: String, eventName: String, status: String, detail: String, chain: [String]) {
        let record = AutomationFiringRecord(
            occurredAt: Date(),
            ruleID: ruleID,
            eventName: eventName,
            status: status,
            detail: String(detail.prefix(2_048)),
            chain: chain
        )
        firingRecords.append(record)
        if firingRecords.count > Self.maximumLogRecords {
            firingRecords.removeFirst(firingRecords.count - Self.maximumLogRecords)
        }
    }

    private func render(_ template: String, event: [String: Any]) -> String {
        var rendered = template
        let payload = event["payload"] as? [String: Any] ?? [:]
        let substitutions: [String: String] = [
            "event.name": event["name"] as? String ?? "",
            "event.category": event["category"] as? String ?? "",
            "event.source": event["source"] as? String ?? ""
        ]
        for (key, value) in substitutions {
            rendered = rendered.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        for (key, value) in payload {
            let text: String
            if let value = value as? String {
                text = value
            } else {
                text = String(describing: value)
            }
            rendered = rendered.replacingOccurrences(of: "{{payload.\(key)}}", with: text)
        }
        return rendered
    }

    private static func normalizedEvent(_ event: [String: Any]) -> [String: Any] {
        var normalized = event
        if normalized["type"] == nil { normalized["type"] = "event" }
        if normalized["payload"] == nil { normalized["payload"] = [:] }
        return normalized
    }

    private static func eventJSON(_ event: [String: Any]) -> String? {
        guard let data = eventJSONData(event) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func eventJSONData(_ event: [String: Any]) -> Data? {
        let sanitized = CmuxEventBus.sanitizedJSONValue(event)
        guard JSONSerialization.isValidJSONObject(sanitized) else { return nil }
        return try? JSONSerialization.data(withJSONObject: sanitized, options: [.sortedKeys])
    }

    private static func encodedChain(_ chain: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: chain, options: []),
              let value = String(data: data, encoding: .utf8) else {
            return chain.joined(separator: ",")
        }
        return value
    }

    private static func uuid(_ raw: String?) -> UUID? {
        guard let raw else { return nil }
        return UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func origin(from event: [String: Any]) -> CmuxAutomationEventOrigin? {
        // The event bus owns the top-level envelope. A payload field is
        // client-controlled data and must never be treated as an internal
        // automation chain marker.
        let raw = event["automation_origin"] as? [String: Any]
        guard let raw,
              let ruleID = raw["rule_id"] as? String else { return nil }
        let chain = (raw["chain"] as? [String] ?? [ruleID])
            .filter { !$0.isEmpty }
            .prefix(Self.maximumChainDepth)
            .map { String($0.prefix(256)) }
        return CmuxAutomationEventOrigin(
            ruleID: ruleID,
            chain: chain.isEmpty ? [String(ruleID.prefix(256))] : chain
        )
    }

    private static func rateLimitPayload(_ limit: AutomationRateLimit) -> [String: Any] {
        ["interval_seconds": limit.intervalSeconds, "maximum": limit.maximum]
    }
}
