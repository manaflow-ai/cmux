import Foundation

/// The one agent page every page-host pane in this test target shows. The agent page's root is
/// registered once per process (the first registration wins, `PageID.registerBundledRoot`), and a
/// whole-target run builds every suite's panes in one process, so they all share it. It is never
/// deleted: the registration outlives any test.
enum AgentPageTestRoot {
    /// Its `index.html`: a 200 by 40 textarea at the body's 8 px margin, and a 16 px button
    /// labelled "Remove red.png" at 300,10.
    static let page: URL? = {
        let directory = FileManager.default.temporaryDirectory.appending(path: "agent-page-test-\(UUID().uuidString)")
        let file = directory.appending(path: "index.html")
        let html = #"<html><body><textarea style="box-sizing:border-box;margin:0;padding:0;border:0;width:200px;height:40px"></textarea><button aria-label="Remove red.png" style="position:absolute;left:300px;top:10px;width:16px;height:16px"></button></body></html>"#
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil,
              (try? Data(html.utf8).write(to: file)) != nil else { return nil }
        return file
    }()
}
