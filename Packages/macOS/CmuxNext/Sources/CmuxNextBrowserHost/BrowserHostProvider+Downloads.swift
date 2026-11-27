import CmuxNextBrowserAutomation
import Foundation

extension BrowserHostProvider {
    /// A download began in tab `targetID` (either engine): `download.started`
    /// with the shape headless Chromium's driver reports. A tab the host does
    /// not know (incognito, another machine's) reports nothing.
    public func reportDownloadStarted(targetID: String, downloadID: String, url: String, suggestedFilename: String) {
        guard connection != nil, announced[targetID] != nil else { return }
        send(.event(name: "download.started", payload: .object([
            "targetId": .string(targetID), "downloadId": .string(downloadID), "url": .string(url),
            "suggestedFilename": .string(suggestedFilename),
        ])))
    }

    /// The download ended: `download.finished` with the saved file's `path`,
    /// or the `error` that ended it.
    public func reportDownloadFinished(targetID: String, downloadID: String, path: String?, error: String?) {
        guard connection != nil, announced[targetID] != nil else { return }
        var payload: [String: DriverJSON] = ["targetId": .string(targetID), "downloadId": .string(downloadID)]
        if let path { payload["path"] = .string(path) } else { payload["error"] = .string(error ?? "the download failed") }
        send(.event(name: "download.finished", payload: .object(payload)))
    }
}
