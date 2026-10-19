import CmuxNextErrorJournal
import CmuxNextHomeEngine
import Foundation

extension ErrorJournalService {
    /// The service for this launch: its own journal folder and every log it can see.
    static func make(environment: AppEnvironment) -> ErrorJournalService {
        let chief = ChiefHome.resolve(tag: environment.tag)
        let home = FileManager().homeDirectoryForCurrentUser
        var sources: [any ErrorHarvestSource] = [
            OSLogErrorSource(),
            LogFileErrorSource(url: chief.acpmuxHome.appendingPathComponent("daemon.log"), source: "acpmux"),
            LogFileErrorSource(url: chief.root.appendingPathComponent("host.log"), source: "chief"),
            LogFileErrorSource(url: chief.root.appendingPathComponent("client.log"), source: "chief"),
            CrashReportErrorSource(),
        ]
        // The app's own acpmux (Release and NIGHTLY share ~/.acpmux) when it is not the Chief's.
        let appAcpmux = home.appendingPathComponent(".acpmux/daemon.log")
        if appAcpmux.standardizedFileURL != chief.acpmuxHome.appendingPathComponent("daemon.log").standardizedFileURL {
            sources.append(LogFileErrorSource(url: appAcpmux, source: "acpmux-app"))
        }
        return ErrorJournalService(journal: ErrorJournal(directory: directory(bundleID: environment.launch.bundleID ?? Bundle.main.bundleIdentifier ?? "com.cmuxterm.app")),
                                   sources: sources)
    }
}
