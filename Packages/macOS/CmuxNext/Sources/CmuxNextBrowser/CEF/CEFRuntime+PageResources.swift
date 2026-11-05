import Foundation

extension CEFRuntime {
    /// Answers a cmux page's request for one of its dynamic paths (PAGE_RESOURCE): the tab's
    /// ``CEFTab/pageResources``, else a 404. Chromium waits for the answer, so every request gets one.
    /// `range` is the request's `Range` header (a video's byte range).
    func answerPageResource(token: Int32, url: String, range: String?, tab: CEFTab?) {
        guard let answer = tab?.pageResources ?? (livePages ? CEFPageSchemes.liveFallback : nil),
              let parsed = URL(string: url) else {
            respond(token: token, with: .notFound)
            return
        }
        // task-owner: one generated file per request; a request the page cancelled is answered into nothing
        Task { @MainActor [weak self] in
            let response = await answer(parsed, range)
            self?.respond(token: token, with: response)
        }
    }

    /// Whether this shim can serve the live web loop to Chromium pages (fork shim with
    /// `cmux_shim_page_scheme_set_live`).
    public var servesLivePages: Bool { shim?.pageSchemeSetLive != nil && shim?.pageResourceRespondPage != nil }

    /// Sends every first-party page file to the page host (`live`), so a page's own
    /// ``CEFTab/pageResources`` answers it from the live web loop, or back to the page folders.
    /// Returns whether the shim took it.
    /// Before the shim loads, the wish is kept and applied when it does (``applyLivePages()``), and
    /// the answer is true: the shim ships with this app, so it serves live pages.
    @discardableResult
    func setLivePages(_ live: Bool) -> Bool {
        livePages = live
        guard let shim else { return true }
        guard servesLivePages, let set = shim.pageSchemeSetLive else { return false }
        set(live ? 1 : 0)
        return true
    }

    /// Applies the kept ``setLivePages(_:)`` wish once the shim has loaded.
    func applyLivePages() {
        if livePages { setLivePages(true) }
    }

    private func respond(token: Int32, with response: CEFPageResponse) {
        guard let shim else { return }
        if let csp = response.csp, let respondPage = shim.pageResourceRespondPage {
            let headers = response.rangeHeaders.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
            _ = response.body.withUnsafeBytes { bytes in
                respondPage(token, Int32(response.status), response.mimeType, headers, csp, bytes.baseAddress, bytes.count)
            }
            return
        }
        guard !response.rangeHeaders.isEmpty else {
            _ = response.body.withUnsafeBytes { bytes in
                shim.pageResourceRespond(token, Int32(response.status), response.mimeType, bytes.baseAddress, bytes.count)
            }
            return
        }
        let headers = response.rangeHeaders.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        _ = response.body.withUnsafeBytes { bytes in
            shim.pageResourceRespondRanged(token, Int32(response.status), response.mimeType, headers, bytes.baseAddress, bytes.count)
        }
    }
}
