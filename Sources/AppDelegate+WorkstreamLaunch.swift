import Foundation
import CMUXWorkstream

extension AppDelegate {
    static func installWorkstreamStoreForLaunch(env: [String: String]) {
        let fileURL = workstreamPersistenceFileURLForLaunch(env: env)
#if DEBUG
        seedFeedActivityPaginationUITestLogIfNeeded(env: env, fileURL: fileURL)
#endif
        FeedCoordinator.shared.install(
            store: WorkstreamStore(
                transport: NullWorkstreamTransport(),
                persistence: WorkstreamPersistence(fileURL: fileURL),
                initialLoadLimit: workstreamInitialLoadLimitForLaunch(env: env),
                historyPageSize: workstreamHistoryPageSizeForLaunch(env: env)
            )
        )
    }

    static func workstreamPersistenceFileURLForLaunch(env: [String: String]) -> URL {
#if DEBUG
        if let path = env["CMUX_UI_TEST_WORKSTREAM_FILE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
#endif
        return WorkstreamPersistence.defaultFileURL()
    }

    static func workstreamInitialLoadLimitForLaunch(env: [String: String]) -> Int {
#if DEBUG
        if let raw = env["CMUX_UI_TEST_WORKSTREAM_INITIAL_LOAD_LIMIT"],
           let value = Int(raw),
           value > 0 {
            return value
        }
#endif
        return WorkstreamDefaultInitialLoadLimit
    }

    static func workstreamHistoryPageSizeForLaunch(env: [String: String]) -> Int {
#if DEBUG
        if let raw = env["CMUX_UI_TEST_WORKSTREAM_HISTORY_PAGE_SIZE"],
           let value = Int(raw),
           value > 0 {
            return value
        }
#endif
        return WorkstreamDefaultHistoryPageSize
    }

#if DEBUG
    static func seedFeedActivityPaginationUITestLogIfNeeded(
        env: [String: String],
        fileURL: URL
    ) {
        guard let rawCount = env["CMUX_UI_TEST_FEED_ACTIVITY_SEED_COUNT"],
              let count = Int(rawCount),
              count > 0 else {
            return
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        var data = Data()
        do {
            for index in 0..<count {
                let item = WorkstreamItem(
                    workstreamId: "opencode-ui-page-\(index)",
                    source: .opencode,
                    kind: .todos,
                    createdAt: baseDate.addingTimeInterval(TimeInterval(index)),
                    cwd: "/tmp/cmux-feed-pagination",
                    status: .telemetry,
                    payload: .todos([]),
                    context: WorkstreamContext(lastUserMessage: "activity pagination seed \(index)")
                )
                data.append(try encoder.encode(item))
                data.append(0x0A)
            }
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            _ = CmuxUITestCapture.mutateJSONObjectIfConfigured(
                envKey: "CMUX_UI_TEST_FEED_ACTIVITY_PAGINATION_PATH"
            ) { payload in
                payload["seeded"] = "1"
                payload["seedCount"] = "\(count)"
                payload["seedPath"] = fileURL.path
            }
        } catch {
            _ = CmuxUITestCapture.mutateJSONObjectIfConfigured(
                envKey: "CMUX_UI_TEST_FEED_ACTIVITY_PAGINATION_PATH"
            ) { payload in
                payload["seeded"] = "0"
                payload["seedError"] = "\(error)"
                payload["seedPath"] = fileURL.path
            }
        }
    }
#else
    static func seedFeedActivityPaginationUITestLogIfNeeded(
        env: [String: String],
        fileURL: URL
    ) {
        _ = env
        _ = fileURL
    }
#endif
}
