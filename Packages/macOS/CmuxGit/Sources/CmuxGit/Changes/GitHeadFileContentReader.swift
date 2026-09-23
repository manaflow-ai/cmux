import Foundation

/// HEAD 커밋에 담긴 파일 내용 조회
///
/// 파일 에디터 거터가 작업 중 버퍼와 비교할 기준을 얻는 용도
/// 추적되지 않는 파일과 저장소 밖 파일은 nil
public struct GitHeadFileContentReader: Sendable {
    /// 기준 내용으로 받아들이는 UTF-8 바이트 상한
    public static let maximumContentByteCount = 2 * 1024 * 1024

    /// 열린 에디터 수만큼 큐가 늘지 않도록 모든 reader 가 공유
    private static let blockingGitQueue = DispatchQueue(
        label: "com.cmux.git-head-content",
        qos: .utility,
        attributes: .concurrent
    )

    private let runner: any WorkspaceChangesGitRunning

    public init() {
        runner = SystemWorkspaceChangesGitRunner()
    }

    init(runner: any WorkspaceChangesGitRunning) {
        self.runner = runner
    }

    /// HEAD 기준 파일 내용
    ///
    /// 1. 파일의 부모 디렉터리에서 실행해 저장소 루트 계산 생략
    /// 2. 경로는 `HEAD:./이름` 형태라 pathspec 이 cwd 에 묶임
    /// 3. 실패와 상한 초과는 모두 nil
    public func headContent(forFile absolutePath: String) async -> String? {
        guard let location = Self.location(ofFile: absolutePath) else { return nil }
        guard let output = await run(
            arguments: ["--literal-pathspecs", "show", "HEAD:./\(location.name)"],
            in: location.directory,
            maximumOutputByteCount: Self.maximumContentByteCount
        ) else { return nil }
        guard output.count <= Self.maximumContentByteCount else { return nil }
        return String(decoding: output, as: UTF8.self)
    }

    /// 파일이 속한 저장소의 인덱스 경로
    ///
    /// 커밋과 스테이징 이후 기준 내용을 다시 읽어야 할 시점을 알기 위한 관찰 대상
    public func indexPath(forFile absolutePath: String) async -> String? {
        guard let location = Self.location(ofFile: absolutePath) else { return nil }
        guard let output = await run(
            arguments: ["rev-parse", "--absolute-git-dir"],
            in: location.directory,
            maximumOutputByteCount: 4096
        ) else { return nil }
        let gitDirectory = String(decoding: output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !gitDirectory.isEmpty else { return nil }
        return URL(fileURLWithPath: gitDirectory, isDirectory: true)
            .appendingPathComponent("index")
            .path
    }

    /// 종료 코드 0 인 실행의 표준 출력
    ///
    /// 잘린 출력은 기준으로 삼을 수 없으므로 nil
    private func run(
        arguments: [String],
        in directory: URL,
        maximumOutputByteCount: Int
    ) async -> Data? {
        let runner = runner
        let result: WorkspaceChangesGitResult? = await withCheckedContinuation { continuation in
            Self.blockingGitQueue.async {
                continuation.resume(returning: try? runner.run(
                    arguments: arguments,
                    in: directory,
                    maximumOutputByteCount: maximumOutputByteCount,
                    wallTimeLimit: 5
                ))
            }
        }
        guard let result, result.exitCode == 0, !result.standardOutputWasTruncated else {
            return nil
        }
        return result.output
    }

    /// 실행 디렉터리와 pathspec 이름으로 분해
    ///
    /// 상대 경로와 상위 참조 이름은 cwd 밖을 가리킬 수 있어 거부
    private static func location(ofFile absolutePath: String) -> (directory: URL, name: String)? {
        guard absolutePath.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: absolutePath)
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        return (url.deletingLastPathComponent(), name)
    }
}
