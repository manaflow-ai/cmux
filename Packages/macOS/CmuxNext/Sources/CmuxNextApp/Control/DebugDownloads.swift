import CmuxNextBrowser
import CmuxNextControl
import CmuxNextSettings
import Foundation

// `debug.downloads` (DEBUG builds): the App's downloads list, oldest first,
// each row's id, file name, status, progress and what the Downloads menu
// offers for it. `pause`, `resume`, `retry` or `cancel` (a row's id) first
// runs that menu item on the row, as a click there does.
enum DebugDownloads {
    static func register(on router: ControlRouter?, services: AppServices) {
        #if DEBUG || CMUX_BENCH_HOOKS
        router?.register([
            .mainActor("debug.downloads") { [weak services] call in
                guard let list = services?.cache.pageRequests.downloads else { return .value(.null) }
                return .value(handle(call.params, list: list))
            },
        ])
        #endif
    }
}

#if DEBUG || CMUX_BENCH_HOOKS
extension DebugDownloads {
    static func handle(_ params: [String: JSONValue], list: BrowserDownloadList) -> JSONValue {
        let row = { (key: String) in params[key]?.stringValue.flatMap { id in list.items.first { $0.id.uuidString == id } } }
        if let item = row("pause") { item.setPaused(true) }
        if let item = row("resume") { item.setPaused(false) }
        if let item = row("retry") { list.retry(item) }
        if let item = row("cancel") { item.cancel() }
        return .object(["downloads": .array(list.items.map(report))])
    }

    private static func report(_ item: BrowserDownload) -> JSONValue {
        let status = switch item.status {
        case .inProgress: "inProgress"
        case .finished: "finished"
        case .failed: "failed"
        case .cancelled: "cancelled"
        case .blocked: "blocked"
        }
        return .object([
            "id": .string(item.id.uuidString),
            "filename": .string(item.filename),
            "status": .string(status),
            "paused": .bool(item.isPaused),
            "canPause": .bool(item.canPause),
            "canRetry": .bool(item.canRetry),
            "received": .number(Double(item.receivedBytes)),
            "total": item.totalBytes.map { .number(Double($0)) } ?? .null,
            "destination": item.destination.map { .string($0.path(percentEncoded: false)) } ?? .null,
        ])
    }
}
#endif
