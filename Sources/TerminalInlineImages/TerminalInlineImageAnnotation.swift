import Foundation

struct TerminalInlineImageAnnotation: Equatable, Identifiable, Sendable {
    let id: UUID
    let rowIndex: Int
    let absoluteRow: Int
    let path: String
    let resolvedPath: String
    let key: TerminalInlineImageAnnotationKey
}

struct TerminalInlineImageAnnotationKey: Hashable, Sendable {
    let absoluteRow: Int
    let canonicalPath: String
}

struct TerminalInlineImageViewport: Sendable {
    let rowOffset: Int
    let maximumAnnotations: Int

    init(rowOffset: Int, maximumAnnotations: Int = 12) {
        self.rowOffset = rowOffset
        self.maximumAnnotations = maximumAnnotations
    }
}

struct TerminalInlineImageReconciler: Sendable {
    func reconcile(
        existing: [TerminalInlineImageAnnotation],
        detectedPaths: [DetectedImagePath],
        viewport: TerminalInlineImageViewport
    ) -> [TerminalInlineImageAnnotation] {
        let existingByKey = Dictionary(existing.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let uniqueDetected = uniqueDetectedPaths(detectedPaths, rowOffset: viewport.rowOffset)
        let capped = mostRecentDetectedPaths(uniqueDetected, maximumCount: viewport.maximumAnnotations)
        return capped.map { detected in
            let absoluteRow = viewport.rowOffset + detected.rowIndex
            let key = TerminalInlineImageAnnotationKey(
                absoluteRow: absoluteRow,
                canonicalPath: detected.resolvedPath
            )
            if let previous = existingByKey[key] {
                return TerminalInlineImageAnnotation(
                    id: previous.id,
                    rowIndex: detected.rowIndex,
                    absoluteRow: absoluteRow,
                    path: detected.path,
                    resolvedPath: detected.resolvedPath,
                    key: key
                )
            }
            return TerminalInlineImageAnnotation(
                id: UUID(),
                rowIndex: detected.rowIndex,
                absoluteRow: absoluteRow,
                path: detected.path,
                resolvedPath: detected.resolvedPath,
                key: key
            )
        }
        .sorted { lhs, rhs in
            if lhs.rowIndex == rhs.rowIndex {
                return lhs.resolvedPath < rhs.resolvedPath
            }
            return lhs.rowIndex < rhs.rowIndex
        }
    }

    private func uniqueDetectedPaths(
        _ detectedPaths: [DetectedImagePath],
        rowOffset: Int
    ) -> [DetectedImagePath] {
        var seen = Set<TerminalInlineImageAnnotationKey>()
        return detectedPaths.filter { detected in
            let key = TerminalInlineImageAnnotationKey(
                absoluteRow: rowOffset + detected.rowIndex,
                canonicalPath: detected.resolvedPath
            )
            return seen.insert(key).inserted
        }
    }

    private func mostRecentDetectedPaths(
        _ detectedPaths: [DetectedImagePath],
        maximumCount: Int
    ) -> [DetectedImagePath] {
        guard maximumCount > 0, detectedPaths.count > maximumCount else {
            return detectedPaths
        }
        return Array(detectedPaths.sorted { lhs, rhs in
            if lhs.rowIndex == rhs.rowIndex {
                return lhs.path > rhs.path
            }
            return lhs.rowIndex > rhs.rowIndex
        }.prefix(maximumCount))
    }
}
