import Foundation

extension CEFRuntime {
    /// Answers a cmux page's request for one of its dynamic paths (PAGE_RESOURCE): the tab's
    /// ``CEFTab/pageResources``, else a 404. Chromium waits for the answer, so every request gets one.
    func answerPageResource(token: Int32, url: String, tab: CEFTab?) {
        guard let answer = tab?.pageResources, let parsed = URL(string: url) else {
            respond(token: token, with: .notFound)
            return
        }
        // task-owner: one generated file per request; a request the page cancelled is answered into nothing
        Task { @MainActor [weak self] in
            let response = await answer(parsed)
            self?.respond(token: token, with: response)
        }
    }

    private func respond(token: Int32, with response: CEFPageResponse) {
        guard let shim else { return }
        _ = response.body.withUnsafeBytes { bytes in
            shim.pageResourceRespond(token, Int32(response.status), response.mimeType, bytes.baseAddress, bytes.count)
        }
    }
}
