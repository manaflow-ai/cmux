import Darwin
import Foundation

/// The bounded result returned by an automation process or webhook action.
nonisolated struct AutomationActionExecutionResult: Sendable {
    let succeeded: Bool
    let detail: String

    static func success(_ detail: String = "ok") -> AutomationActionExecutionResult {
        AutomationActionExecutionResult(succeeded: true, detail: detail)
    }

    static func failure(_ detail: String) -> AutomationActionExecutionResult {
        AutomationActionExecutionResult(succeeded: false, detail: detail)
    }
}

/// A bounded in-process bridge from ``CmuxEventBus`` to configured actions.
///
/// The engine is main-actor owned because notification delivery and the v2
/// dispatcher are main-actor domains. Event consumption itself happens on a
/// utility task and only schedules small, ordered decisions back to this
/// owner. No event-log tailer is involved.
@MainActor
final class AutomationEngine {
    typealias NotificationHandler = @MainActor (UUID, UUID?, String, String, String) -> Void
    typealias ProcessRunner = @Sendable (String, [String: String]) async -> AutomationActionExecutionResult
    typealias WebhookRunner = @Sendable (URL, [String: String], Data) async -> AutomationActionExecutionResult
    typealias WorkspaceTagsResolver = @MainActor (UUID) -> [String]

    private static let maximumLogRecords = 256
    private static let maximumChainDepth = 16
    private static let maximumConcurrentFirings = 32
    private static let defaultRateLimit = AutomationRateLimit(intervalSeconds: 1, maximum: 1)

    private let configStore: AutomationConfigStore
    private let eventBus: CmuxEventBus
    private let notificationHandler: NotificationHandler
    private let processRunner: ProcessRunner?
    private let webhookRunner: WebhookRunner?
    private let workspaceTagsResolver: WorkspaceTagsResolver

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
        processRunner: ProcessRunner? = nil,
        webhookRunner: WebhookRunner? = nil,
        workspaceTagsResolver: @escaping WorkspaceTagsResolver = { _ in [] }
    ) {
        self.configStore = configStore
        self.eventBus = eventBus
        self.notificationHandler = notificationHandler
        self.processRunner = processRunner
        self.webhookRunner = webhookRunner
        self.workspaceTagsResolver = workspaceTagsResolver
    }

    deinit {
        subscription?.close()
        eventTask?.cancel()
        restartTask?.cancel()
        firingTasks.values.forEach { $0.cancel() }
    }

    /// Starts the live subscription. Calling this more than once is harmless.
    func start() {
        shouldRun = true
        guard eventTask == nil else { return }
        _ = reload()
        if eventTask == nil {
            installSubscription(afterSequence: nil)
        }
    }

    private func installSubscription(afterSequence: Int64?) {
        guard shouldRun, rules.contains(where: \.enabled) else { return }
        let filters = subscriptionFilters()
        let snapshot = eventBus.subscribe(
            afterSequence: afterSequence,
            names: filters.names,
            categories: filters.categories
        )
        subscription = snapshot.subscription
        let subscription = snapshot.subscription
        restartTask?.cancel()
        restartTask = nil
        for event in snapshot.replay {
            receive(event)
        }
        eventTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let event = subscription.next(timeout: CmuxEventBus.defaultHeartbeatIntervalSeconds),
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
        // A slow consumer closes its bounded queue. Re-arm from the current
        // tail with bounded exponential backoff; an event flood must not turn
        // recovery into an allocation loop.
        guard restartTask == nil else { return }
        let delay = min(5.0, 0.25 * pow(2.0, Double(min(restartAttempt, 5))))
        restartAttempt = min(restartAttempt + 1, 5)
        let cursor = lastSequence
        restartTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            guard let self, self.shouldRun else { return }
            self.restartTask = nil
            self.installSubscription(afterSequence: cursor)
        }
    }

    /// Stops the live subscription and wakes a blocked event read.
    func stop() {
        shouldRun = false
        restartTask?.cancel()
        restartTask = nil
        subscription?.close()
        if let subscription {
            eventBus.unsubscribe(subscription)
        }
        subscription = nil
        eventTask?.cancel()
        eventTask = nil
        firingTasks.values.forEach { $0.cancel() }
        firingTasks.removeAll(keepingCapacity: true)
        workspaceTagsCache.removeAll(keepingCapacity: true)
        pendingTagResolutions.removeAll(keepingCapacity: true)
    }

    /// Reloads the file and returns a compact command response.
    @discardableResult
    func reload() -> Result<Int, Error> {
        do {
            let configuration = try configStore.load()
            rules = configuration.rules
            rebuildRuleIndexes()
            fireDatesByRuleID.removeAll(keepingCapacity: true)
            workspaceTagsCache.removeAll(keepingCapacity: true)
            pendingTagResolutions.removeAll(keepingCapacity: true)
            if shouldRun {
                if let subscription {
                    eventBus.unsubscribe(subscription)
                    subscription.close()
                    self.subscription = nil
                }
                eventTask?.cancel()
                eventTask = nil
                installSubscription(afterSequence: lastSequence)
            }
            return .success(rules.count)
        } catch {
            rules.removeAll(keepingCapacity: true)
            rulesByEventName.removeAll(keepingCapacity: true)
            rulesByCategory.removeAll(keepingCapacity: true)
            unindexedRules.removeAll(keepingCapacity: true)
            fireDatesByRuleID.removeAll(keepingCapacity: true)
            workspaceTagsCache.removeAll(keepingCapacity: true)
            pendingTagResolutions.removeAll(keepingCapacity: true)
            if let subscription {
                eventBus.unsubscribe(subscription)
                subscription.close()
                self.subscription = nil
            }
            eventTask?.cancel()
            eventTask = nil
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

    private func rebuildRuleIndexes() {
        rulesByEventName.removeAll(keepingCapacity: true)
        rulesByCategory.removeAll(keepingCapacity: true)
        unindexedRules.removeAll(keepingCapacity: true)
        for rule in rules {
            let exactEvent = rule.when.event.flatMap { value in
                value.isEmpty || value.contains("*") ? nil : value
            }
            let exactCategory = rule.when.category.flatMap { value in
                value.isEmpty || value.contains("*") ? nil : value
            }
            if let exactEvent, rule.when.category == nil {
                rulesByEventName[exactEvent, default: []].append(rule)
            } else if let exactCategory, rule.when.event == nil {
                rulesByCategory[exactCategory, default: []].append(rule)
            } else {
                unindexedRules.append(rule)
            }
        }
    }

    private func subscriptionFilters() -> (names: Set<String>, categories: Set<String>) {
        let enabledRules = rules.filter(\.enabled)
        guard !enabledRules.isEmpty else { return ([], []) }
        let exactEvents = enabledRules.compactMap { rule -> String? in
            guard let event = rule.when.event,
                  !event.isEmpty,
                  !event.contains("*"),
                  rule.when.category == nil else { return nil }
            return event
        }
        if exactEvents.count == enabledRules.count {
            return (Set(exactEvents), [])
        }
        let exactCategories = enabledRules.compactMap { rule -> String? in
            guard let category = rule.when.category,
                  !category.isEmpty,
                  !category.contains("*"),
                  rule.when.event == nil else { return nil }
            return category
        }
        if exactCategories.count == enabledRules.count {
            return ([], Set(exactCategories))
        }
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
              let data = try? JSONEncoder().encode(rule),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    func setEnabled(id: String, enabled: Bool) -> Result<AutomationRule, Error> {
        do {
            let rule = try configStore.updateRule(id: id) { rule in
                rule.enabled = enabled
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
                installSubscription(afterSequence: lastSequence)
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
            "event": normalized,
            "actions": rule.actions.map(Self.actionPayload),
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
            _ = reload()
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
                await self?.execute(rule: rule, event: normalized, chain: chain)
                self?.firingTasks.removeValue(forKey: firingID)
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
        candidates.append(contentsOf: rulesByEventName[eventName] ?? [])
        if let category {
            candidates.append(contentsOf: rulesByCategory[category] ?? [])
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
        defer { concurrentFirings = max(0, concurrentFirings - 1) }
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
        let response = await TerminalController.shared.performAutomationRPC(
            method: method,
            params: params,
            allowFocus: allowFocus,
            origin: origin
        )
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
        guard let rawURL = action.string(for: "url"),
              let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              url.host != nil,
              ["http", "https"].contains(scheme) else {
            return .failure("webhook action requires an http(s) url")
        }
        guard let data = Self.eventJSONData(event) else {
            return .failure("could not serialize automation event")
        }
        var headers: [String: String] = ["Content-Type": "application/json"]
        for (key, value) in (action.object(for: "headers") ?? [:]).prefix(64) {
            if let string = value.stringValue {
                headers[String(key.prefix(256))] = String(string.prefix(8_192))
            }
        }
        if let webhookRunner {
            return await webhookRunner(url, headers, data)
        }
        return await runWebhook(url: url, headers: headers, data: data)
    }

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
            await withTaskGroup(of: AutomationActionExecutionResult.self) { group in
                group.addTask {
                    await session.run()
                }
                group.addTask {
                    do {
                        let nanoseconds = UInt64(timeoutSeconds * 1_000_000_000)
                        try await Task.sleep(nanoseconds: nanoseconds)
                        await session.terminate()
                        return .failure("command timed out after \(timeoutSeconds) seconds")
                    } catch {
                        return .success("process timeout cancelled")
                    }
                }
                let result = await group.next() ?? .failure("process did not return a result")
                group.cancelAll()
                return result
            }
        }, onCancel: {
            Task { await session.terminate() }
        })
    }

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
        let session = URLSession(configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 20
            return configuration
        }())
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
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
        let raw = event["automation_origin"] as? [String: Any]
            ?? (event["payload"] as? [String: Any])?["automation_origin"] as? [String: Any]
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

    private static func actionPayload(_ action: AutomationAction) -> [String: Any] {
        var payload: [String: Any] = ["action": action.action]
        for (key, value) in action.parameters { payload[key] = value.foundationObject }
        return payload
    }

    private static func rateLimitPayload(_ limit: AutomationRateLimit) -> [String: Any] {
        ["interval_seconds": limit.intervalSeconds, "maximum": limit.maximum]
    }
}

/// Owns one shell process and exposes a cancellable termination stream.
/// Keeping the Foundation Process inside an actor avoids crossing its
/// non-Sendable handle between the firing task and the timeout task.
actor AutomationProcessSession {
    private let process: Process
    private let command: String
    private let environment: [String: String]
    private var ownedProcessGroupID: pid_t?

    init(command: String, environment: [String: String]) {
        self.command = command
        self.environment = environment
        self.process = Process()
        self.ownedProcessGroupID = nil
    }

    func run() async -> AutomationActionExecutionResult {
        let (stream, continuation) = AsyncStream<Int32>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { process in
            continuation.yield(process.terminationStatus)
            continuation.finish()
        }
        do {
            try process.run()
            let processID = process.processIdentifier
            // Foundation has no pre-exec hook on macOS. Move the shell into a
            // private process group immediately after launch and keep the
            // single-PID fallback when the OS refuses setpgid.
            if processID > 1, setpgid(processID, processID) == 0 {
                ownedProcessGroupID = processID
            }
        } catch {
            process.terminationHandler = nil
            continuation.finish()
            return .failure("could not run command: \(error.localizedDescription)")
        }
        for await status in stream {
            guard status == 0 else {
                return .failure("command exited with status \(status)")
            }
            return .success("command completed")
        }
        return .failure("process ended without a termination status")
    }

    func terminate() {
        guard process.isRunning else { return }
        if let ownedProcessGroupID, ownedProcessGroupID > 1 {
            _ = kill(-ownedProcessGroupID, SIGTERM)
            _ = kill(-ownedProcessGroupID, SIGKILL)
        }
        process.terminate()
    }
}

/// A bounded, JSON-friendly record retained by the engine's firing ring.
nonisolated struct AutomationFiringRecord: Sendable {
    let occurredAt: Date
    let ruleID: String
    let eventName: String
    let status: String
    let detail: String
    let chain: [String]

    var payload: [String: Any] {
        [
            "occurred_at": CmuxEventBus.isoTimestamp(occurredAt),
            "rule_id": ruleID,
            "event": eventName,
            "status": status,
            "detail": detail,
            "chain": chain
        ]
    }
}
