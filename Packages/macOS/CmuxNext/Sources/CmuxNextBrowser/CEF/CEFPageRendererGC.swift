import CmuxNextWakeups
import Foundation

/// Collects what closed cmux pages leave behind in the renderer they shared.
///
/// Every agent chat is `cmux-page://cmux.agent/`, and the fork gives such a scheme one renderer per site
/// (`CEFSwitches.processPerSitePageSchemes`), so a closed chat's heap (JavaScript and DOM) becomes garbage in a
/// renderer that lives on, and the idle renderer does not collect it: on cmux13s (DEV, 10 workspaces, a chat
/// opened and closed every ~2.5 s) the chat renderer grew 324 -> 572 MB over 600 closes while its live heap
/// stayed at 55-90 MB and its pages and documents at 3. Chrome never meets this: a closed tab's renderer exits.
/// A memory-pressure notice does not reclaim it (a moderate one left the heap growing, 389 -> 576 MB used in 15 s
/// of churn); one full collection (`HeapProfiler.collectGarbage`) took that renderer from 1100 to 484 MB, in
/// about 220 ms.
///
/// So every cmux page close (a chat closed, a hidden chat released) checks, ``delay`` after the first close of a
/// burst, each renderer that still hosts cmux pages, through one of its live pages: a renderer whose heap has
/// grown past ``bound(afterLastCollection:)`` gets one full collection. A renderer of chats that stay open is
/// checked too, at most once per ``delay``, and the bound keeps the blocking collection rare: it runs only once
/// the garbage is about as large as what is live.
@MainActor
final class CEFPageRendererGC {
    static let delay: Duration = .seconds(10)
    /// The least growth worth a blocking collection, and the live size assumed before the first one.
    static let floorBytes = 64 << 20

    /// A live page, as the check picks its targets.
    struct Page: Equatable {
        var browser: Int32
        var isCmuxPage: Bool
        var rendererClients: [Int32]
    }

    /// One check target: a renderer and the live page its calls go through.
    struct Target: Equatable {
        var renderer: Int32
        var browser: Int32
    }

    private let timer = DemandTimer(owner: "CEFPageRendererGC")
    private let pages: @MainActor () -> [Page]
    private let heapUsed: @MainActor (Int32) async -> Int?
    private let collect: @MainActor (Int32) async -> Void
    /// Each renderer's used heap right after its last collection.
    private var live: [Int32: Int] = [:]
    private var checking = false

    init(pages: @escaping @MainActor () -> [Page],
         heapUsed: @escaping @MainActor (Int32) async -> Int?,
         collect: @escaping @MainActor (Int32) async -> Void) {
        self.pages = pages
        self.heapUsed = heapUsed
        self.collect = collect
    }

    /// A cmux page closed: its renderer is checked within ``delay``.
    func pageClosed() {
        timer.scheduleIfIdle(after: Self.delay) { @MainActor [weak self] in await self?.check() }
    }

    func check() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        let targets = Self.targets(pages())
        live = live.filter { renderer, _ in targets.contains { $0.renderer == renderer } }
        for target in targets {
            guard let used = await heapUsed(target.browser), used >= Self.bound(afterLastCollection: live[target.renderer]) else { continue }
            await collect(target.browser)
            if let after = await heapUsed(target.browser) { live[target.renderer] = after }
        }
    }

    /// The used heap at which a renderer is collected: twice what was live after its last collection, and at
    /// least ``floorBytes`` more.
    static func bound(afterLastCollection live: Int?) -> Int {
        let live = max(live ?? floorBytes, 0)
        return max(2 * live, live + floorBytes)
    }

    /// One cmux page per renderer that hosts cmux pages (the lowest browser id of its main-frame renderer), in
    /// browser order. A page whose renderer is unknown is skipped: a page still loading has nothing to collect.
    static func targets(_ pages: [Page]) -> [Target] {
        var byRenderer: [Int32: Int32] = [:]
        for page in pages where page.isCmuxPage {
            guard let renderer = page.rendererClients.first else { continue }
            byRenderer[renderer] = min(byRenderer[renderer] ?? page.browser, page.browser)
        }
        return byRenderer.map { Target(renderer: $0.key, browser: $0.value) }.sorted { $0.browser < $1.browser }
    }

    static func isCmuxPage(_ url: URL?) -> Bool { url?.scheme == "cmux-page" }

    /// `usedSize` of a `Runtime.getHeapUsage` result.
    static func usedSize(_ json: String) -> Int? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let used = object["usedSize"] as? NSNumber else { return nil }
        return used.intValue
    }
}
