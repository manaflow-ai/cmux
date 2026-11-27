import Foundation

extension MenuBarProfilingProgressWindowController {
    func makeTemporaryLogFile(prefix: String) throws -> (URL, FileHandle) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return (url, try FileHandle(forWritingTo: url))
    }

    func readLogText(from url: URL?) -> String {
        guard let url, let data = try? Data(contentsOf: url), !data.isEmpty else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func removeLogFile(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
