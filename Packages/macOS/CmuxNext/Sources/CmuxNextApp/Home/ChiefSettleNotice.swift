import Foundation

/// The Chief conversation's notice while a turn waits for the compactor to
/// summarize the view: `<chief home>/state/settle.json`, written by the host
/// only while a turn waits (optchat-chief settle_status.rs). After a large
/// import the first settle takes minutes; the notice says how far it is.
nonisolated struct ChiefSettleNotice {
    /// The notice for the file's contents; nil when it is not a wait.
    static func text(json: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let built = object["built"] as? Int, let total = object["total"] as? Int,
              built >= 0, built < total else { return nil }
        return HomeStrings.chiefOrganizing(built: built, total: total)
    }
}

/// Watches the Chief home's `state/` folder (the host renames `settle.json`
/// into it, or removes it) and reports the notice on every change; nil when
/// no turn waits. Kernel events on the folder, no polling.
nonisolated final class ChiefSettleWatch {
    private let source: DispatchSourceFileSystemObject?

    /// `report` runs on the main actor with the current notice, once now and
    /// after every change of the folder.
    init(home: ChiefHome, report: @escaping @MainActor @Sendable (String?) -> Void) {
        let folder = home.settleStatusFile.deletingLastPathComponent()
        let file = home.settleStatusFile
        let queue = DispatchQueue(label: "com.cmuxterm.app.next.chief-settle")
        let send: @Sendable (String?) -> Void = { text in Task { @MainActor in report(text) } }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fd = open(folder.path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
            source.setCancelHandler { close(fd) }
            source.setEventHandler { Self.read(file, send) }
            source.resume()
            self.source = source
        } else {
            source = nil
        }
        queue.async { Self.read(file, send) }
    }

    deinit { source?.cancel() }

    func cancel() { source?.cancel() }

    private static func read(_ file: URL, _ send: @Sendable (String?) -> Void) {
        // concurrency-allow: runs on the watch queue (a small JSON file), never the main actor.
        let data = try? Data(contentsOf: file)
        send(data.flatMap(ChiefSettleNotice.text(json:)))
    }
}
