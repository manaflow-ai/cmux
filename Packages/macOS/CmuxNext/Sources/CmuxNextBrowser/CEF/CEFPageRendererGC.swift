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
///
/// That bound alone leaves the last burst's garbage behind for good: up to ``floorBytes`` (or what is live) of V8
/// heap below it, with the DOM and Blink memory those closed pages' wrappers hold. Infinite tabs (500 tabs, 200
/// workspaces, 100 chats, all hibernated) ended with only two chat pages in this renderer and it still at 368 MB
/// footprint against about 163 MB in the empty app. So ``quietDelay`` after the newest close, once closes stop,
/// each renderer is checked once more against the lower ``quietBound(afterLastCollection:)``: a collection then
/// costs one pause proportional to what is live (two pages), once, and no churn pays it.
///
/// The quiet check collects twice. One collection left the renderer at 655 MB resident on the same bench, and a
/// second `HeapProfiler.collectGarbage` right after took it to 543 MB: the first frees the JavaScript wrappers,
/// and the DOM they kept goes with the next. The second costs the same small pause, once per quiet period.
@MainActor
final class CEFPageRendererGC {
    static let delay: Duration = .seconds(10)
    /// The least growth worth a blocking collection, and the live size assumed before the first one.
    static let floorBytes = 64 << 20
    /// From the newest cmux page close to the quiet check (each close moves it).
    static let quietDelay: Duration = .seconds(60)
    /// The least garbage the quiet check collects.
    static let quietFloorBytes = 16 << 20

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
    private let quietTimer = DemandTimer(owner: "CEFPageRendererGC.quiet")
    private let pages: @MainActor () -> [Page]
    private let heapUsed: @MainActor (Int32) async -> Int?
    private let collect: @MainActor (Int32) async -> Void
    /// Each renderer's used heap right after its last collection.
    private var live: [Int32: Int] = [:]
    private var checking = false
    /// What the collector did, for `debug.cef_pages` (a bench reads why a renderer was or was not collected).
    private(set) var stats: [String: Int] = [:]
    private func count(_ key: String, _ value: Int? = nil) { stats[key] = value ?? (stats[key, default: 0] + 1) }
    /// Runs at the end of every check (the App's chat renderer recycle, `CEFChatRendererRecycle`).
    var checked: (@MainActor () async -> Void)?

    init(pages: @escaping @MainActor () -> [Page],
         heapUsed: @escaping @MainActor (Int32) async -> Int?,
         collect: @escaping @MainActor (Int32) async -> Void) {
        self.pages = pages
        self.heapUsed = heapUsed
        self.collect = collect
    }

    /// A cmux page closed: its renderer is checked within ``delay``, and once more ``quietDelay`` after the newest close.
    func pageClosed() {
        count("closes")
        timer.scheduleIfIdle(after: Self.delay) { @MainActor [weak self] in await self?.check() }
        scheduleQuietCheck()
    }

    private func scheduleQuietCheck() {
        quietTimer.schedule(after: Self.quietDelay) { @MainActor [weak self] in await self?.check(quiet: true) }
    }

    /// `quiet`: the check once closes stopped, against ``quietBound(afterLastCollection:)``.
    func check(quiet: Bool = false) async {
        guard !checking else {
            // The burst's check is running: the quiet one still runs, later.
            if quiet { scheduleQuietCheck() }
            count("busy")
            return
        }
        checking = true
        defer { checking = false }
        let targets = Self.targets(pages())
        count(quiet ? "quiet_checks" : "checks")
        count("last_targets", targets.count)
        live = live.filter { renderer, _ in targets.contains { $0.renderer == renderer } }
        for target in targets {
            let bound = quiet ? Self.quietBound(afterLastCollection: live[target.renderer]) : Self.bound(afterLastCollection: live[target.renderer])
            let used = await heapUsed(target.browser)
            count("last_used_mb", (used ?? -(1 << 20)) >> 20)
            count("last_bound_mb", bound >> 20)
            guard let used, used >= bound else { continue }
            await collect(target.browser)
            count(quiet ? "quiet_collections" : "collections")
            // What the first collection unhooked (closed pages' DOM, freed by the wrappers that went) goes back
            // only with a second one.
            if quiet {
                await collect(target.browser)
                count("quiet_second_collections")
            }
            if let after = await heapUsed(target.browser) { live[target.renderer] = after; count("last_live_mb", after >> 20) }
        }
        await checked?()
    }

    /// The used heap at which a renderer is collected: twice what was live after its last collection, and at
    /// least ``floorBytes`` more.
    static func bound(afterLastCollection live: Int?) -> Int {
        let live = max(live ?? floorBytes, 0)
        return max(2 * live, live + floorBytes)
    }

    /// The used heap at which the quiet check collects: ``quietFloorBytes`` more than was live after the last
    /// collection; with none yet, past ``quietFloorBytes`` (that collection learns what is live).
    static func quietBound(afterLastCollection live: Int?) -> Int {
        max(live ?? 0, 0) + quietFloorBytes
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

    /// `usedSize` of a `Runtime.getHeapUsage` result, decoded off the main actor.
    @concurrent nonisolated static func usedSize(_ json: String) async -> Int? {
        guard let data = json.data(using: .utf8),
              // main-actor-ok: one DevTools Runtime.getHeapUsage reply, two numbers ({usedSize, totalSize}).
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let used = object["usedSize"] as? NSNumber else { return nil }
        return used.intValue
    }
}
