import PDFKit

struct FilePreviewPDFPageRotationState {
    private var deltasByPageIndex: [Int: Int] = [:]

    mutating func reset() {
        deltasByPageIndex.removeAll(keepingCapacity: true)
    }

    mutating func record(page: PDFPage, in document: PDFDocument, rotationBy degrees: Int) {
        let pageIndex = document.index(for: page)
        guard pageIndex >= 0 else { return }
        let delta = Self.normalized((deltasByPageIndex[pageIndex] ?? 0) + degrees)
        if delta == 0 {
            deltasByPageIndex.removeValue(forKey: pageIndex)
        } else {
            deltasByPageIndex[pageIndex] = delta
        }
    }

    func apply(to document: PDFDocument?) {
        guard let document else { return }
        for (pageIndex, delta) in deltasByPageIndex {
            guard pageIndex < document.pageCount,
                  let page = document.page(at: pageIndex) else { continue }
            page.rotation = Self.normalized(page.rotation + delta)
        }
    }

    private static func normalized(_ degrees: Int) -> Int {
        ((degrees % 360) + 360) % 360
    }
}
