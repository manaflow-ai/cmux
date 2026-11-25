#if os(iOS)
import CmuxMobileLinkFFI
import Foundation
import UIKit

/// The heights the app's chat rows were measured at, kept by Rust (`RowLayoutMemory`,
/// cmux-mobile-link-ffi `row_layout.rs`) across transcript pages and launches. A page built
/// again (a top-bar swipe back to a tab, the app opened again on a chat) asks it, in one keyed
/// diff per change, for the rows it has not measured yet: a row whose id, content, disclosures
/// and width are unchanged since it was measured is laid out at that height at once, so its
/// cell's measurement moves nothing (Leo, 2026-11-24: "the loading has layout shifts ... better
/// diffed"). A changed or new row starts at its estimate, as before; every cell still measures
/// itself, so a kept height that is wrong is corrected the way an estimate is.
@MainActor
final class ChatRowHeightMemory {
    /// The app's memory; none in unit tests (each list measures on its own there) or with
    /// `CMUX_MOBILE_ROW_MEMORY=0` (the before column of `LoadShiftsUITests`).
    static let shared: ChatRowHeightMemory? = {
        let environment = ProcessInfo.processInfo.environment
        guard environment["XCTestConfigurationFilePath"] == nil, environment["CMUX_MOBILE_ROW_MEMORY"] != "0" else { return nil }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        return ChatRowHeightMemory(path: caches?.appendingPathComponent("chat-row-heights.tsv").path)
    }()

    /// Rows kept across every chat; past it the least recently used quarter goes.
    static let capacity: UInt32 = 6000

    private let memory = RowLayoutMemory(capacity: capacity)
    private let path: String?
    private var observer: NSObjectProtocol?

    init(path: String?) {
        self.path = path
        if let path { _ = memory.load(path: path) }
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }
    }

    /// Writes the heights for the next launch, off the main thread.
    func save() {
        guard let path else { return }
        let memory = memory
        DispatchQueue.global(qos: .utility).async { _ = memory.save(path: path) }
    }

    /// What `row` draws, as a fingerprint that is the same on every launch.
    func fingerprint(_ row: ChatRow) -> UInt64 {
        rowLayoutFingerprint(text: "\(row.gap)|\(String(describing: row.kind))")
    }

    /// The kept height of each row, in order (nil: changed or new): one keyed diff in Rust.
    func heights(scope: String, width: CGFloat, rows: [(id: String, content: UInt64, fold: Int)]) -> [CGFloat?] {
        guard !rows.isEmpty else { return [] }
        let keys = rows.map { RowLayoutKey(id: $0.id, content: $0.content, fold: UInt32(truncatingIfNeeded: $0.fold)) }
        return memory.diff(scope: scope, width: Double(width), keys: keys).map { diff in
            if case .unchanged(let height) = diff { return CGFloat(height) }
            return nil
        }
    }

    func record(scope: String, width: CGFloat, id: String, content: UInt64, fold: Int, height: CGFloat) {
        memory.record(scope: scope, width: Double(width),
                      key: RowLayoutKey(id: id, content: content, fold: UInt32(truncatingIfNeeded: fold)), height: Double(height))
    }

    /// The probe's fields (`LoadFrameProbe`).
    var stats: [String: Any] {
        let stats = memory.stats()
        return ["memoryRows": stats.rows, "memoryUnchanged": stats.unchanged, "memoryChanged": stats.changed, "memoryNew": stats.new]
    }
}
#endif
