import CmuxFilePreviewCore
import CmuxGit
import Foundation

/// 파일 에디터 거터가 칠할 git 변경 줄을 유지
///
/// 1. 기준 내용은 HEAD 커밋
/// 2. 버퍼 변경은 디바운스 후 계산해 타이핑 경로를 막지 않음
/// 3. 커밋과 스테이징은 인덱스 관찰로 감지해 기준을 다시 읽음
@MainActor
final class FilePreviewGitDiffTracker {
    /// 연속 타이핑을 한 번의 계산으로 묶는 간격
    private static let recomputeDebounce = Duration.milliseconds(150)

    private let filePath: String
    private let reader: GitHeadFileContentReader
    private let onChange: @MainActor ([Int: FilePreviewGitLineChange]) -> Void

    private var baseContent: String?
    private var latestText = ""
    private var baseTask: Task<Void, Never>?
    private var recomputeTask: Task<Void, Never>?
    /// 늦게 끝난 계산이 최신 결과를 덮어쓰지 못하게 하는 세대 번호
    private var recomputeGeneration = 0
    private var indexObservationID: UUID?
    private weak var indexCoordinator: FileContentChangeCoordinator?
    /// 이전 coordinator 로 향하던 관찰 설치를 무효화하는 세대 번호
    private var indexWatchGeneration = 0

    private(set) var changes: [Int: FilePreviewGitLineChange] = [:]

    init(
        filePath: String,
        reader: GitHeadFileContentReader = GitHeadFileContentReader(),
        onChange: @escaping @MainActor ([Int: FilePreviewGitLineChange]) -> Void
    ) {
        self.filePath = filePath
        self.reader = reader
        self.onChange = onChange
    }

    /// 인덱스 변경 관찰 시작
    ///
    /// 저장소 밖 파일은 인덱스가 없어 관찰하지 않음
    func startWatchingIndex(using coordinator: FileContentChangeCoordinator) {
        stopWatchingIndex()
        let reader = reader
        let filePath = filePath
        let generation = indexWatchGeneration
        Task { [weak self, weak coordinator] in
            guard let indexPath = await reader.indexPath(forFile: filePath) else { return }
            guard let self, let coordinator else { return }
            guard self.indexWatchGeneration == generation, self.indexObservationID == nil else {
                return
            }
            self.indexCoordinator = coordinator
            self.indexObservationID = coordinator.observe(path: indexPath) { [weak self] in
                self?.refreshBase()
            }
        }
    }

    func stopWatchingIndex() {
        indexWatchGeneration += 1
        if let indexObservationID {
            self.indexObservationID = nil
            indexCoordinator?.removeObservation(indexObservationID)
        }
        indexCoordinator = nil
    }

    /// HEAD 기준 내용을 다시 읽고 표시 갱신
    func refreshBase() {
        baseTask?.cancel()
        let reader = reader
        let filePath = filePath
        baseTask = Task { [weak self] in
            let content = await reader.headContent(forFile: filePath)
            guard !Task.isCancelled, let self else { return }
            self.baseContent = content
            self.recomputeNow()
        }
    }

    /// 편집 버퍼 반영
    ///
    /// 기준이 아직 없으면 계산을 건너뛰어 첫 로드 중 깜빡임 방지
    func update(currentText: String) {
        latestText = currentText
        guard baseContent != nil else { return }
        recompute(debounced: true)
    }

    func cancel() {
        baseTask?.cancel()
        baseTask = nil
        recomputeTask?.cancel()
        recomputeTask = nil
        recomputeGeneration += 1
        stopWatchingIndex()
    }

    private func recomputeNow() {
        recompute(debounced: false)
    }

    /// 표시 재계산
    ///
    /// 기준이 없으면 추적되지 않는 파일이므로 표시를 비움
    private func recompute(debounced: Bool) {
        recomputeTask?.cancel()
        recomputeGeneration += 1
        let generation = recomputeGeneration
        guard let baseContent else {
            recomputeTask = nil
            publish([:])
            return
        }
        let current = latestText
        recomputeTask = Task { [weak self] in
            if debounced {
                try? await Task.sleep(for: Self.recomputeDebounce)
                guard !Task.isCancelled else { return }
            }
            let next = await Task.detached(priority: .utility) {
                FilePreviewGitLineDiff.changes(base: baseContent, current: current)
            }.value
            guard let self, self.recomputeGeneration == generation else { return }
            self.publish(next)
        }
    }

    private func publish(_ next: [Int: FilePreviewGitLineChange]) {
        guard next != changes else { return }
        changes = next
        onChange(next)
    }
}
