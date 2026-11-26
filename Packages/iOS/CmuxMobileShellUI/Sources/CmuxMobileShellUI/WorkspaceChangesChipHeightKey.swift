/// Bounded layout characteristics that can change a workspace changes chip's height.
struct WorkspaceChangesChipHeightKey: Hashable, Sendable {
    enum Mode: Hashable, Sendable {
        case singleFile
        case multipleFiles
        case lineCounts
    }

    let mode: Mode
    let fileDigitCount: Int
    let additionDigitCount: Int
    let deletionDigitCount: Int
    let isInteractive: Bool

    init(
        filesChanged: Int,
        additions: Int,
        deletions: Int,
        isInteractive: Bool
    ) {
        if additions != 0 || deletions != 0 {
            mode = .lineCounts
        } else if filesChanged == 1 {
            mode = .singleFile
        } else {
            mode = .multipleFiles
        }
        fileDigitCount = Self.digitCount(filesChanged)
        additionDigitCount = Self.digitCount(additions)
        deletionDigitCount = Self.digitCount(deletions)
        self.isInteractive = isInteractive
    }

    private static func digitCount(_ value: Int) -> Int {
        String(max(0, value)).count
    }
}
