@testable import CmuxNextControl
import CmuxNextCompat
import CmuxNextSettings
import Foundation
import Testing

/// `browser.page.upload` answers the page's file chooser (`.upload`, real files of any size, from any element
/// that opens one); only a file input whose page opened no chooser gets the files through a page script.
/// `browser.page.downloads` and `browser.page.download.wait` (`cmux browser … download`) read the app's
/// downloads; before, cmux NEXT had no way for an agent to list or wait for one.
@Suite(.timeLimit(.minutes(1))) struct BrowserPageUploadTests {
    final class ChooserEngine: BrowserPageEngine {
        let chooser: String
        let fileInput: Bool
        let operations = Mutex<[BrowserPageOperation]>([])
        let queries = Mutex<[BrowserPageDownloadQuery]>([])
        let download: BrowserPageDownload?
        /// How long each answer takes (a chooser that opens late, a download that runs).
        let delay: Duration

        init(chooser: String, fileInput: Bool = false, download: BrowserPageDownload? = nil, delay: Duration = .zero) {
            self.chooser = chooser
            self.fileInput = fileInput
            self.download = download
            self.delay = delay
        }

        func run(_ operation: BrowserPageOperation, tabID: String, url: String?) async throws -> JSONValue {
            operations.withLock { $0.append(operation) }
            if delay > .zero { try await Task.sleep(for: delay) }
            if case .upload = operation {
                return ["chooser": .string(chooser), "value": ["value": ["fileInput": .bool(fileInput)]]]
            }
            return ["value": ["value": ["files": ["a.txt"]]]]
        }

        func downloads(_ query: BrowserPageDownloadQuery) async throws -> BrowserPageDownloads {
            queries.withLock { $0.append(query) }
            if delay > .zero { try await Task.sleep(for: delay) }
            guard query.wait != nil else { return .list([]) }
            return download.map(BrowserPageDownloads.ended) ?? .timedOut
        }

        var uploads: [BrowserPageUpload] {
            operations.withLock { $0.compactMap { if case .upload(let upload) = $0 { upload } else { nil } } }
        }
        var scripts: [String] {
            operations.withLock { $0.compactMap { if case .evaluate(let script) = $0 { script } else { nil } } }
        }
    }

    func install(_ engine: ChooserEngine, requestDeadline: Duration = .seconds(2)) -> ControlRouter {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(),
                                   configuration: .init(requestDeadline: requestDeadline))
        BrowserPageService(engine: engine).install(on: router)
        var snapshot = ControlSnapshot.sample()
        let tab = ControlTabInfo(id: "tab_0123abcd", surface: "12", kind: "browser", title: "Form", url: "https://example.com/")
        snapshot.topology.workspaces[0].screens[0].panes[0].tabs.append(tab)
        router.snapshots.publish { $0 = snapshot }
        return router
    }

    func call(_ router: ControlRouter, _ method: String, _ params: [String: JSONValue]) async -> Result<JSONValue, ControlError> {
        var params = params
        params["tab"] = "tab_0123abcd"
        return await router.handle(ControlRequest(method: method, params: params))
    }

    func scratch(_ names: [String], bytes: Int = 4) throws -> (URL, [String]) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cn-upload-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let paths = names.map { folder.appendingPathComponent($0).path }
        for path in paths { FileManager.default.createFile(atPath: path, contents: Data(count: bytes)) }
        return (folder, paths)
    }

    /// A button that opens the chooser takes the files, and a file past the page-script cap still goes:
    /// nothing is read, the chooser gets the path.
    @Test func aChooserTakesTheFilesWithNoSizeCapAndNoPageScript() async throws {
        let (folder, paths) = try scratch(["big.bin"], bytes: BrowserPageService.uploadLimit + 1)
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = ChooserEngine(chooser: "chosen")
        let router = install(engine)

        let result = try await call(router, "browser.page.upload", ["selector": "#upload-button", "files": .array(paths.map(JSONValue.string))]).get()

        #expect(result["value"]?["files"] == ["big.bin"])
        #expect(result["value"]?["chooser"] == true)
        let upload = try #require(engine.uploads.first)
        #expect(upload.files.map(\.path) == paths)
        #expect(upload.script.contains("#upload-button") && upload.script.contains("el.click()"))
        #expect(upload.within == .seconds(3))
        #expect(engine.scripts.isEmpty, "the bytes went through a page script too")
    }

    @Test func aFileInputWhosePageOpenedNoChooserGetsTheFilesThroughThePage() async throws {
        let (folder, paths) = try scratch(["a.txt"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = ChooserEngine(chooser: "withdrawn", fileInput: true)
        let router = install(engine)

        _ = try await call(router, "browser.page.upload", ["selector": "#f", "files": .array(paths.map(JSONValue.string)), "timeout_ms": 500]).get()

        #expect(engine.uploads.first?.within == .milliseconds(500))
        #expect(engine.scripts.count == 1 && engine.scripts[0].contains("new W.DataTransfer()"))
    }

    @Test func aClickThatOpensNoChooserOnAnythingElseIsAnError() async throws {
        let (folder, paths) = try scratch(["a.txt"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let router = install(ChooserEngine(chooser: "withdrawn"))

        let answer = await call(router, "browser.page.upload", ["selector": "#nothing", "files": .array(paths.map(JSONValue.string))])

        #expect(answer.controlError?.code == "no_file_chooser")
    }

    @Test(arguments: ["too_many_files", "needs_folder", "needs_files", "save_chooser"])
    func aChooserThatCannotTakeTheFilesSaysWhy(_ refusal: String) async throws {
        let (folder, paths) = try scratch(["a.txt", "b.txt"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let router = install(ChooserEngine(chooser: refusal))

        let answer = await call(router, "browser.page.upload", ["selector": "#f", "files": .array(paths.map(JSONValue.string))])

        #expect(answer.controlError?.code == refusal)
    }

    @Test func aMissingFileIsRefusedBeforeAnyClick() async throws {
        let engine = ChooserEngine(chooser: "chosen")
        let router = install(engine)

        let answer = await call(router, "browser.page.upload", ["selector": "#f", "files": ["/nonexistent/cmux-upload.txt"]])

        #expect(answer.controlError?.code == "not_found")
        #expect(engine.operations.withLock { $0.isEmpty })
    }

    @Test func downloadsListAndWaitReachTheEngineForTheTab() async throws {
        let engine = ChooserEngine(chooser: "chosen")
        let router = install(engine)

        _ = try await call(router, "browser.page.downloads", ["limit": 5]).get()
        let waited = await call(router, "browser.page.download.wait", ["id": "AB12", "timeout_ms": 1500])
        #expect(waited.controlError?.code == "timeout")

        let queries = engine.queries.withLock { $0 }
        #expect(queries == [
            BrowserPageDownloadQuery(tabID: "tab_0123abcd", limit: 5),
            BrowserPageDownloadQuery(tabID: "tab_0123abcd", id: "AB12", wait: .milliseconds(1500)),
        ])
    }

    @Test func aFinishedDownloadIsCopiedWhereTheWaitSays() async throws {
        let (folder, paths) = try scratch(["report.pdf"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = ChooserEngine(chooser: "chosen", download: BrowserPageDownload(id: "AB12", filename: "report.pdf", status: "finished", path: paths[0]))
        let router = install(engine)
        let target = folder.appendingPathComponent("out", isDirectory: true).path + "/"

        let result = try await call(router, "browser.page.download.wait", ["path": .string(target)]).get()

        let saved = folder.appendingPathComponent("out/report.pdf").path
        #expect(result["path"] == .string(saved))
        #expect(FileManager.default.fileExists(atPath: saved))
        #expect(FileManager.default.fileExists(atPath: paths[0]), "the Downloads list's file moved")
        #expect(result["download"]?["filename"] == "report.pdf")
    }

    /// `--path ~/Downloads` names the download's own folder: the file stays and its path is the answer.
    @Test func aPathThatIsTheDownloadItselfKeepsTheFile() async throws {
        let (folder, paths) = try scratch(["report.pdf"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = ChooserEngine(chooser: "chosen", download: BrowserPageDownload(id: "AB12", filename: "report.pdf", status: "finished", path: paths[0]))
        let router = install(engine)

        let result = try await call(router, "browser.page.download.wait", ["path": .string(folder.path)]).get()

        #expect(FileManager.default.fileExists(atPath: paths[0]), "the wait deleted the download it was asked to copy")
        #expect(result["path"] == .string(paths[0]))
    }

    /// The same file spelled in another case (a case-insensitive volume) is the download itself.
    @Test func aPathNamingTheDownloadInAnotherCaseKeepsTheFile() async throws {
        let (folder, paths) = try scratch(["report.pdf"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = ChooserEngine(chooser: "chosen", download: BrowserPageDownload(id: "AB12", filename: "report.pdf", status: "finished", path: paths[0]))
        let router = install(engine)

        _ = await call(router, "browser.page.download.wait", ["path": .string(folder.appendingPathComponent("Report.PDF").path)])

        #expect(FileManager.default.fileExists(atPath: paths[0]), "the wait deleted the download it was asked to copy")
    }

    /// Another file already at the target is never replaced: the wait refuses and both files stay.
    @Test func anExistingFileAtThePathIsRefusedAndKept() async throws {
        let (folder, paths) = try scratch(["report.pdf", "keep.pdf"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = ChooserEngine(chooser: "chosen", download: BrowserPageDownload(id: "AB12", filename: "report.pdf", status: "finished", path: paths[0]))
        let router = install(engine)

        let answer = await call(router, "browser.page.download.wait", ["path": .string(paths[1])])

        #expect(answer.controlError?.code == "io_error")
        #expect(FileManager.default.fileExists(atPath: paths[0]) && FileManager.default.fileExists(atPath: paths[1]))
    }

    /// An upload whose chooser takes its 3 s and a download that runs for minutes outlive the control plane's
    /// request deadline (2 s in the app): both methods carry their own. Before, the router answered `timeout`
    /// at 2 s, so a click that opened no chooser never said so and no real download could be waited for.
    @Test func uploadAndDownloadWaitOutliveTheControlPlaneDeadline() async throws {
        let (folder, paths) = try scratch(["a.txt"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let done = BrowserPageDownload(id: "AB12", filename: "a.txt", status: "finished", path: paths[0])
        let router = install(ChooserEngine(chooser: "withdrawn", download: done, delay: .milliseconds(300)), requestDeadline: .milliseconds(50))

        let upload = await call(router, "browser.page.upload", ["selector": "#nothing", "files": .array(paths.map(JSONValue.string))])
        let wait = await call(router, "browser.page.download.wait", [:])

        #expect(upload.controlError?.code == "no_file_chooser", "\(String(describing: upload.controlError))")
        #expect(wait.controlError == nil, "\(String(describing: wait.controlError))")
    }

    @Test func aDownloadThatDidNotFinishFailsTheWaitWithItsRow() async throws {
        let failed = BrowserPageDownload(id: "AB12", filename: "big.iso", status: "failed", reason: "Network error")
        let router = install(ChooserEngine(chooser: "chosen", download: failed))

        let answer = await call(router, "browser.page.download.wait", [:])

        #expect(answer.controlError?.code == "download_failed")
        #expect(answer.controlError?.data?["reason"] == "Network error")
    }
}

private extension Result {
    var controlError: Failure? {
        if case .failure(let error) = self { error } else { nil }
    }
}
