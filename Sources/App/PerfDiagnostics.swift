#if DEBUG
import CMUXDebugLog
import CmuxSettings
import Foundation
import os.signpost

final class PerfDiagnostics: @unchecked Sendable {
    static let shared = PerfDiagnostics()

    enum Scope {
        case title
        case sidebar
        case mobile
        case renderer
    }

    private enum Counter: String, CaseIterable {
        case titleNotifications
        case titleDroppedEmpty
        case titleEnqueues
        case titleFlushes
        case titleApplies
        case titleMutations
        case titleNoops
        case sidebarImmediateInvalidations
        case sidebarDebouncedInvalidations
        case mobileObserverEmits
        case mobileObserverSkips
        case rendererVisibilityChanges
        case rendererVisibilityRequests
        case rendererRefreshes
    }

    private enum SignpostName {
        case titleNotification
        case titleFlush
        case sidebarInvalidation
        case mobileObserver
        case rendererVisibility
        case rendererRefresh
    }

    private struct Config: Equatable {
        var enabled: Bool
        var intervalSeconds: TimeInterval
        var verboseEvents: Bool
        var signposts: Bool
        var jsonDump: Bool
        var jsonDumpPath: String
        var titleScope: Bool
        var sidebarScope: Bool
        var mobileScope: Bool
        var rendererScope: Bool

        static let disabled = Config(
            enabled: false,
            intervalSeconds: 5,
            verboseEvents: false,
            signposts: false,
            jsonDump: false,
            jsonDumpPath: "",
            titleScope: true,
            sidebarScope: true,
            mobileScope: true,
            rendererScope: true
        )

        func isEnabled(scope: Scope) -> Bool {
            switch scope {
            case .title:
                return titleScope
            case .sidebar:
                return sidebarScope
            case .mobile:
                return mobileScope
            case .renderer:
                return rendererScope
            }
        }

        var enabledScopesDescription: String {
            var scopes: [String] = []
            if titleScope { scopes.append("title") }
            if sidebarScope { scopes.append("sidebar") }
            if mobileScope { scopes.append("mobile") }
            if rendererScope { scopes.append("renderer") }
            return scopes.joined(separator: ",")
        }

        var resolvedJSONDumpPath: String {
            if !jsonDumpPath.isEmpty {
                return jsonDumpPath
            }
            let env = ProcessInfo.processInfo.environment
            let rawTag = env["CMUX_TAG"] ?? Bundle.main.bundleIdentifier ?? "cmux"
            let tag = PerfDiagnostics.token(rawTag)
            return "/tmp/cmux-perf-\(tag)-\(ProcessInfo.processInfo.processIdentifier).jsonl"
        }
    }

    private struct JSONRecord: Encodable {
        var type: String
        var uptime: Double
        var pid: Int32
        var kind: String?
        var fields: [String: String]?
        var counters: [String: Int]?
        var config: [String: String]?
    }

    private static let signpostLog = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "com.cmuxterm.app",
        category: "PerfDiagnostics"
    )

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let settingsCatalog = SettingCatalog()
    private let ioQueue = DispatchQueue(label: "cmux.perf-diagnostics.io")

    private var config = Config.disabled
    private var lastConfigReadUptime = -Double.infinity
    private var lastSummaryUptime = ProcessInfo.processInfo.systemUptime
    private var counters: [String: Int] = [:]
    private var emittedHeader = false

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func recordTitleNotification(tabId: UUID, panelId: UUID, title: String) {
        record(
            .titleNotifications,
            scope: .title,
            fields: titleFields(tabId: tabId, panelId: panelId, title: title),
            signpost: .titleNotification
        )
    }

    func recordTitleDroppedEmpty(tabId: UUID, panelId: UUID) {
        record(
            .titleDroppedEmpty,
            scope: .title,
            fields: [
                "panel": Self.short(panelId),
                "ws": Self.short(tabId),
            ],
            signpost: .titleNotification
        )
    }

    func recordTitleEnqueue(tabId: UUID, panelId: UUID, title: String) {
        record(
            .titleEnqueues,
            scope: .title,
            fields: titleFields(tabId: tabId, panelId: panelId, title: title),
            signpost: .titleNotification
        )
    }

    func recordTitleFlush(pendingCount: Int) {
        record(
            .titleFlushes,
            scope: .title,
            fields: ["pending": "\(pendingCount)"],
            signpost: .titleFlush
        )
    }

    func recordTitleApply(
        tabId: UUID,
        panelId: UUID,
        mutated: Bool,
        focused: Bool,
        selected: Bool,
        title: String
    ) {
        var fields = titleFields(tabId: tabId, panelId: panelId, title: title)
        fields["focused"] = Self.flag(focused)
        fields["mutated"] = Self.flag(mutated)
        fields["selected"] = Self.flag(selected)
        record(.titleApplies, scope: .title, fields: fields, signpost: .titleNotification)
    }

    func recordTitleMutation(
        workspaceId: UUID,
        panelId: UUID,
        mutated: Bool,
        panelChanged: Bool,
        workspaceChanged: Bool,
        panelCount: Int,
        hasCustomTitle: Bool,
        title: String
    ) {
        var fields = titleFields(tabId: workspaceId, panelId: panelId, title: title)
        fields["custom"] = Self.flag(hasCustomTitle)
        fields["mutated"] = Self.flag(mutated)
        fields["panelChanged"] = Self.flag(panelChanged)
        fields["panelCount"] = "\(panelCount)"
        fields["wsChanged"] = Self.flag(workspaceChanged)
        record(
            mutated ? .titleMutations : .titleNoops,
            scope: .title,
            fields: fields,
            signpost: .titleNotification
        )
    }

    func recordSidebarInvalidation(
        workspaceId: UUID,
        source: String,
        title: String,
        descriptionLength: Int
    ) {
        let normalizedSource = Self.token(source)
        record(
            normalizedSource == "immediate" ? .sidebarImmediateInvalidations : .sidebarDebouncedInvalidations,
            scope: .sidebar,
            fields: [
                "descLen": "\(descriptionLength)",
                "source": normalizedSource,
                "titleHash": Self.fingerprint(title),
                "titleLen": "\(Self.length(title))",
                "ws": Self.short(workspaceId),
            ],
            signpost: .sidebarInvalidation
        )
    }

    func recordMobileObserver(result: String, summaryHash: Int, tabCount: Int, force: Bool) {
        let normalizedResult = Self.token(result)
        record(
            normalizedResult == "emit" ? .mobileObserverEmits : .mobileObserverSkips,
            scope: .mobile,
            fields: [
                "force": Self.flag(force),
                "result": normalizedResult,
                "summaryHash": "\(summaryHash)",
                "tabs": "\(tabCount)",
            ],
            signpost: .mobileObserver
        )
    }

    func recordRendererVisibility(
        surfaceId: UUID?,
        workspaceId: UUID?,
        visible: Bool,
        changed: Bool
    ) {
        record(
            changed ? .rendererVisibilityChanges : .rendererVisibilityRequests,
            scope: .renderer,
            fields: [
                "changed": Self.flag(changed),
                "surface": Self.short(surfaceId),
                "visible": Self.flag(visible),
                "ws": Self.short(workspaceId),
            ],
            signpost: .rendererVisibility
        )
    }

    func recordRendererRefresh(surfaceId: UUID?, workspaceId: UUID?, reason: String) {
        record(
            .rendererRefreshes,
            scope: .renderer,
            fields: [
                "surface": Self.short(surfaceId),
                "why": Self.token(reason),
                "ws": Self.short(workspaceId),
            ],
            signpost: .rendererRefresh
        )
    }

    private func record(
        _ counter: Counter,
        scope: Scope,
        fields: [String: String],
        signpost: SignpostName
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        var lines: [String] = []
        var jsonLines: [String] = []
        var jsonPath: String?
        var shouldSignpost = false

        lock.lock()
        refreshConfigIfNeededLocked(now: now)
        let currentConfig = config
        guard currentConfig.enabled, currentConfig.isEnabled(scope: scope) else {
            lock.unlock()
            return
        }

        if !emittedHeader {
            let headerFields = makeHeaderFields(config: currentConfig)
            lines.append("perf.diagnostics.enabled \(Self.formatFields(headerFields))")
            if currentConfig.jsonDump {
                jsonLines.append(Self.jsonLine(
                    type: "header",
                    uptime: now,
                    config: headerFields
                ))
            }
            emittedHeader = true
        }

        counters[counter.rawValue, default: 0] += 1
        if currentConfig.verboseEvents {
            lines.append("perf.event kind=\(counter.rawValue) \(Self.formatFields(fields))")
        }
        if currentConfig.jsonDump {
            jsonLines.append(Self.jsonLine(
                type: "event",
                uptime: now,
                kind: counter.rawValue,
                fields: fields
            ))
        }

        if now - lastSummaryUptime >= currentConfig.intervalSeconds {
            let summary = currentCountersSnapshotLocked()
            lines.append(
                "perf.summary uptime=\(Self.formatSeconds(now)) " +
                "interval=\(Self.formatSeconds(now - lastSummaryUptime)) " +
                Self.formatCounters(summary)
            )
            if currentConfig.jsonDump {
                jsonLines.append(Self.jsonLine(type: "summary", uptime: now, counters: summary))
            }
            counters.removeAll(keepingCapacity: true)
            lastSummaryUptime = now
            shouldSignpost = currentConfig.signposts
        } else {
            shouldSignpost = currentConfig.signposts
        }

        if currentConfig.jsonDump {
            jsonPath = currentConfig.resolvedJSONDumpPath
        }
        lock.unlock()

        if shouldSignpost {
            Self.emitSignpost(signpost)
        }
        for line in lines {
            cmuxDebugLog(line)
        }
        if let jsonPath, !jsonLines.isEmpty {
            writeJSONLines(jsonLines, to: jsonPath)
        }
    }

    private func refreshConfigIfNeededLocked(now: TimeInterval) {
        guard now - lastConfigReadUptime >= 1 else { return }
        lastConfigReadUptime = now

        let client = UserDefaultsSettingsClient(defaults: defaults)
        let performance = settingsCatalog.performance
        let next = Config(
            enabled: client.value(for: performance.diagnosticsEnabled),
            intervalSeconds: max(1, client.value(for: performance.diagnosticsIntervalSeconds)),
            verboseEvents: client.value(for: performance.diagnosticsVerboseEventsEnabled),
            signposts: client.value(for: performance.diagnosticsSignpostsEnabled),
            jsonDump: client.value(for: performance.diagnosticsJSONDumpEnabled),
            jsonDumpPath: client.value(for: performance.diagnosticsJSONDumpPath)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            titleScope: client.value(for: performance.diagnosticsTitleScopeEnabled),
            sidebarScope: client.value(for: performance.diagnosticsSidebarScopeEnabled),
            mobileScope: client.value(for: performance.diagnosticsMobileScopeEnabled),
            rendererScope: client.value(for: performance.diagnosticsRendererScopeEnabled)
        )

        if config != next {
            emittedHeader = false
            counters.removeAll(keepingCapacity: true)
            lastSummaryUptime = now
        }
        config = next
    }

    private func currentCountersSnapshotLocked() -> [String: Int] {
        var snapshot: [String: Int] = [:]
        for counter in Counter.allCases {
            snapshot[counter.rawValue] = counters[counter.rawValue] ?? 0
        }
        return snapshot
    }

    private func makeHeaderFields(config: Config) -> [String: String] {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        let commit = (info["CMUXGitCommit"] as? String)
            ?? (info["GitCommit"] as? String)
            ?? (info["GIT_COMMIT"] as? String)
            ?? "unknown"

        return [
            "appBuild": Self.token(build),
            "appVersion": Self.token(version),
            "commit": Self.token(commit),
            "debugLog": DebugEventLog.currentLogPath(),
            "interval": Self.formatSeconds(config.intervalSeconds),
            "jsonDump": Self.flag(config.jsonDump),
            "jsonOut": config.resolvedJSONDumpPath,
            "pid": "\(ProcessInfo.processInfo.processIdentifier)",
            "scopes": config.enabledScopesDescription,
            "signposts": Self.flag(config.signposts),
            "tag": Self.token(ProcessInfo.processInfo.environment["CMUX_TAG"] ?? "none"),
            "verbose": Self.flag(config.verboseEvents),
        ]
    }

    private func writeJSONLines(_ lines: [String], to path: String) {
        guard !lines.isEmpty else { return }
        let payload = lines.joined(separator: "\n") + "\n"
        ioQueue.async {
            let url = URL(fileURLWithPath: path)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard let data = payload.data(using: .utf8) else { return }
            if let handle = FileHandle(forWritingAtPath: path) {
                defer { try? handle.close() }
                guard (try? handle.seekToEnd()) != nil else { return }
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func titleFields(tabId: UUID, panelId: UUID, title: String) -> [String: String] {
        [
            "panel": Self.short(panelId),
            "titleHash": Self.fingerprint(title),
            "titleLen": "\(Self.length(title))",
            "ws": Self.short(tabId),
        ]
    }

    private static func emitSignpost(_ name: SignpostName) {
        switch name {
        case .titleNotification:
            os_signpost(.event, log: signpostLog, name: "title.notification")
        case .titleFlush:
            os_signpost(.event, log: signpostLog, name: "title.flush")
        case .sidebarInvalidation:
            os_signpost(.event, log: signpostLog, name: "sidebar.invalidation")
        case .mobileObserver:
            os_signpost(.event, log: signpostLog, name: "mobile.observer")
        case .rendererVisibility:
            os_signpost(.event, log: signpostLog, name: "renderer.visibility")
        case .rendererRefresh:
            os_signpost(.event, log: signpostLog, name: "renderer.refresh")
        }
    }

    private static func jsonLine(
        type: String,
        uptime: TimeInterval,
        kind: String? = nil,
        fields: [String: String]? = nil,
        counters: [String: Int]? = nil,
        config: [String: String]? = nil
    ) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let record = JSONRecord(
            type: type,
            uptime: uptime,
            pid: ProcessInfo.processInfo.processIdentifier,
            kind: kind,
            fields: fields,
            counters: counters,
            config: config
        )
        guard let data = try? encoder.encode(record),
              let line = String(data: data, encoding: .utf8) else {
            return #"{"type":"encodeError"}"#
        }
        return line
    }

    private static func formatFields(_ fields: [String: String]) -> String {
        fields.keys.sorted().map { key in
            "\(key)=\(fields[key] ?? "")"
        }.joined(separator: " ")
    }

    private static func formatCounters(_ counters: [String: Int]) -> String {
        Counter.allCases.map { counter in
            "\(counter.rawValue)=\(counters[counter.rawValue] ?? 0)"
        }.joined(separator: " ")
    }

    private static func flag(_ value: Bool) -> String {
        value ? "1" : "0"
    }

    private static func formatSeconds(_ value: TimeInterval) -> String {
        String(format: "%.3f", value)
    }

    private static func short(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        return String(id.uuidString.prefix(8))
    }

    private static func length(_ text: String) -> Int {
        (text as NSString).length
    }

    private static func fingerprint(_ text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private static func token(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "none" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-/:"))
        return String(trimmed.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "_"
        })
    }
}
#endif
