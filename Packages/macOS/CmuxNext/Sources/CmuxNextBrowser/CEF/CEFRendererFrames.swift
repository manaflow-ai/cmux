/// Every frame of every browser this process's Chromium holds, by browser and renderer
/// (`cmux_shim_renderer_frames`): what memory per hidden workspace splits a shared renderer by.
/// The list covers every browser the shim holds (tabs, popups, popup windows,
/// spares, DevTools), so ``totals`` is each renderer's whole frame count, the denominator Chrome splits a
/// process's memory by (components/performance_manager/resource_attribution/attribution_helpers.h,
/// `SplitResourceAmongFramesAndWorkers`).
public nonisolated struct CEFRendererFrames: Sendable, Equatable {
    /// How many frames (the main frame and every iframe) of one browser one renderer hosts.
    public nonisolated struct Entry: Sendable, Equatable {
        public var browser: Int32
        /// The renderer's client id (its helper's `--renderer-client-id`).
        public var clientID: Int32
        public var frames: Int

        public init(browser: Int32, clientID: Int32, frames: Int) {
            self.browser = browser
            self.clientID = clientID
            self.frames = frames
        }
    }

    public let entries: [Entry]
    /// Each renderer client id's frames over every browser.
    public let totals: [Int32: Int]
    private let byBrowser: [Int32: [Entry]]

    public init(_ entries: [Entry]) {
        self.entries = entries
        totals = entries.reduce(into: [:]) { $0[$1.clientID, default: 0] += $1.frames }
        byBrowser = Dictionary(grouping: entries, by: \.browser)
    }

    /// Each renderer hosting `browser`'s frames, with how many it hosts. Empty for no browser (nil) and for one
    /// the shim does not hold (not created yet, closed): it has no frame, so no renderer memory.
    public func frames(ofBrowser browser: Int32?) -> [(clientID: Int32, frames: Int)] {
        guard let browser else { return [] }
        return (byBrowser[browser] ?? []).map { (clientID: $0.clientID, frames: $0.frames) }
    }
}

extension CEFEngine {
    /// ``CEFRendererFrames`` now: one in-process shim call, stock CEF API. Nil in host mode (the renderers are
    /// the Chromium Host's children); empty before Chromium's library is loaded (no browser).
    public var rendererFrames: CEFRendererFrames? { CEFRuntime.shared.rendererFrames }
}

extension CEFRuntime {
    /// See ``CEFEngine/rendererFrames``.
    var rendererFrames: CEFRendererFrames? {
        guard hostStart == nil else { return nil }
        guard let shim else { return CEFRendererFrames([]) }
        return shim.rendererFrames().map(CEFRendererFrames.init)
    }
}
