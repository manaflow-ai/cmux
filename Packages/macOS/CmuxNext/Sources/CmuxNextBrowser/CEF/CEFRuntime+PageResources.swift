import Foundation

extension CEFRuntime {
    /// Answers a cmux page's request for one of its dynamic paths (PAGE_RESOURCE): the tab's
    /// ``CEFTab/pageResources``, else a 404. Chromium waits for the answer, so every request gets one.
    /// An answer ready after its host ended is dropped: the request went with that host, and the next
    /// host's tokens count from 1 again, so it would answer another page's request.
    func answerPageResource(token: Int32, url: String, tab: CEFTab?) {
        guard let answer = tab?.pageResources, let parsed = URL(string: url) else {
            respond(token: token, with: .notFound)
            return
        }
        let asker = hostStart?.generation
        // task-owner: one generated file per request; a request the page cancelled is answered into nothing
        Task { @MainActor [weak self] in
            let response = await answer(parsed)
            guard let self, hostStart?.generation == asker else { return }
            respond(token: token, with: response)
        }
    }

    /// In host mode `cmux_shim_page_resource_respond` is a post to the Chromium Host, its body in a sealed
    /// shared memory region past 64 KiB (task 020) and at most ``CEFPageResponse/hostBodyLimit``.
    private func respond(token: Int32, with response: CEFPageResponse) {
        guard let shim else { return }
        let answer = hostStart == nil ? response : response.fittingHostWire
        _ = shim.pageResourceRespond(token, Int32(answer.status), answer.mimeType, answer.body)
    }
}
