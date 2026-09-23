import Foundation

/// 거터 한 줄에 칠할 git 변경 종류
public enum FilePreviewGitLineChange: Sendable, Equatable {
    case added // base 에 없던 줄
    case modified // base 의 줄을 대체한 줄
    case removed // 이 줄 바로 위에서 base 의 줄이 사라짐
    case removedAtEnd // 이 줄 아래에서 base 의 줄이 사라짐
}

/// 작업 중 버퍼와 git base 내용의 줄 단위 비교
///
/// 1. 결과 키는 현재 버퍼의 1-based 줄 번호
/// 2. 삭제는 자체 줄이 없으므로 살아남은 이웃 줄에 부착
/// 3. 삽입과 삭제가 맞물린 구간은 modified
/// 4. 한계를 넘는 입력은 빈 결과
public enum FilePreviewGitLineDiff {
    /// 비교를 포기하는 줄 수 상한
    public static let maximumLineCount = 20_000
    /// 비교를 포기하는 UTF-8 바이트 상한
    public static let maximumByteCount = 2 * 1024 * 1024

    /// base 대비 현재 버퍼의 변경 줄 계산
    ///
    /// 메인 스레드 밖에서 호출
    public static func changes(
        base: String,
        current: String
    ) -> [Int: FilePreviewGitLineChange] {
        guard base.utf8.count <= maximumByteCount,
              current.utf8.count <= maximumByteCount else { return [:] }
        let baseLines = lines(of: base)
        let currentLines = lines(of: current)
        guard baseLines.count <= maximumLineCount,
              currentLines.count <= maximumLineCount else { return [:] }
        guard baseLines != currentLines else { return [:] }

        let difference = currentLines.difference(from: baseLines)
        var removedBaseOffsets: Set<Int> = []
        var insertedCurrentOffsets: Set<Int> = []
        for change in difference {
            switch change {
            case let .remove(offset, _, _):
                removedBaseOffsets.insert(offset)
            case let .insert(offset, _, _):
                insertedCurrentOffsets.insert(offset)
            }
        }
        return markers(
            baseLineCount: baseLines.count,
            currentLineCount: currentLines.count,
            removedBaseOffsets: removedBaseOffsets,
            insertedCurrentOffsets: insertedCurrentOffsets
        )
    }

    /// 두 수열을 나란히 걸으며 변경 구간을 모아 표시
    ///
    /// 삭제 오프셋은 base 좌표이고 삽입 오프셋은 현재 좌표라 같은 걸음에서
    /// 소비해야 두 좌표계가 어긋나지 않음
    private static func markers(
        baseLineCount: Int,
        currentLineCount: Int,
        removedBaseOffsets: Set<Int>,
        insertedCurrentOffsets: Set<Int>
    ) -> [Int: FilePreviewGitLineChange] {
        var result: [Int: FilePreviewGitLineChange] = [:]
        var baseIndex = 0
        var currentIndex = 0
        var runRemovalCount = 0
        var runInsertedLines: [Int] = []

        while baseIndex < baseLineCount || currentIndex < currentLineCount {
            if baseIndex < baseLineCount, removedBaseOffsets.contains(baseIndex) {
                runRemovalCount += 1
                baseIndex += 1
                continue
            }
            if currentIndex < currentLineCount, insertedCurrentOffsets.contains(currentIndex) {
                runInsertedLines.append(currentIndex)
                currentIndex += 1
                continue
            }
            flush(
                removalCount: runRemovalCount,
                insertedLines: runInsertedLines,
                anchorLine: currentIndex,
                currentLineCount: currentLineCount,
                into: &result
            )
            runRemovalCount = 0
            runInsertedLines.removeAll(keepingCapacity: true)
            baseIndex += 1
            currentIndex += 1
        }
        flush(
            removalCount: runRemovalCount,
            insertedLines: runInsertedLines,
            anchorLine: currentIndex,
            currentLineCount: currentLineCount,
            into: &result
        )
        return result
    }

    /// 변경 구간 하나를 표시로 환산
    ///
    /// 1. 삽입만 있으면 added
    /// 2. 삽입과 삭제가 함께면 삽입 줄 전부 modified
    /// 3. 삭제만 있으면 뒤따르는 줄에 removed
    /// 4. 뒤따르는 줄이 없으면 마지막 줄에 removedAtEnd
    private static func flush(
        removalCount: Int,
        insertedLines: [Int],
        anchorLine: Int,
        currentLineCount: Int,
        into result: inout [Int: FilePreviewGitLineChange]
    ) {
        guard removalCount > 0 || !insertedLines.isEmpty else { return }
        if !insertedLines.isEmpty {
            let kind: FilePreviewGitLineChange = removalCount > 0 ? .modified : .added
            for line in insertedLines {
                result[line + 1] = kind
            }
            return
        }
        if anchorLine < currentLineCount {
            result[anchorLine + 1] = .removed
        } else if currentLineCount > 0 {
            result[currentLineCount] = .removedAtEnd
        }
    }

    /// 개행으로 분리
    ///
    /// 끝 개행이 만드는 빈 꼬리는 제거해 git 의 줄 세기와 일치시킴
    /// CRLF 의 캐리지 리턴도 제거해 줄바꿈 표기 차이를 변경으로 오인하지 않음
    private static func lines(of text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var result = text.components(separatedBy: "\n")
        if result.last == "" {
            result.removeLast()
        }
        return result.map { line in
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }
    }
}
