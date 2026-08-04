#if os(iOS) && DEBUG
import CmuxMobileChanges

struct ChangesPreviewFixture: Sendable {
    let branch = "feat/ios-diff-viewer"
    let base = "origin/main"
    let files: [ChangedFileItem]
    let totals: ChangesTotals
    let documents: [String: FileDiffDocument]

    init() {
        files = [
            ChangedFileItem(
                path: "README.md",
                kind: .added,
                additions: 6,
                deletions: 0,
                isBinary: false
            ),
            ChangedFileItem(
                path: "Resources/PreviewHero.png",
                kind: .modified,
                additions: 0,
                deletions: 0,
                isBinary: true,
                byteSize: 2_485_760
            ),
            ChangedFileItem(
                path: "Sources/SessionStore.swift",
                kind: .modified,
                additions: 5,
                deletions: 3,
                isBinary: false
            ),
            ChangedFileItem(
                path: "Sources/LegacySession.swift",
                kind: .deleted,
                additions: 0,
                deletions: 5,
                isBinary: false
            ),
            ChangedFileItem(
                path: "Sources/WorkspaceSession.swift",
                oldPath: "Sources/ProjectSession.swift",
                kind: .renamed,
                additions: 2,
                deletions: 2,
                isBinary: false
            ),
            ChangedFileItem(
                path: "Sources/Scratchpad.swift",
                kind: .untracked,
                additions: 5,
                deletions: 0,
                isBinary: false
            ),
            ChangedFileItem(
                path: "Generated/Schema.swift",
                kind: .modified,
                additions: 6000,
                deletions: 0,
                isBinary: false
            ),
        ]
        totals = ChangesTotals(filesChanged: 7, additions: 6018, deletions: 10)
        let parser = UnifiedDiffParser()
        documents = [
            "README.md": parser.parse(Self.addedDiff),
            "Resources/PreviewHero.png": parser.parse("", isBinary: true),
            "Sources/SessionStore.swift": parser.parse(Self.modifiedSwiftDiff),
            "Sources/LegacySession.swift": parser.parse(Self.deletedDiff),
            "Sources/WorkspaceSession.swift": parser.parse(Self.renamedDiff),
            "Sources/Scratchpad.swift": parser.parse(Self.untrackedDiff),
            "Generated/Schema.swift": parser.parse(Self.truncatedDiff, truncated: true),
        ]
    }

    private static let addedDiff = """
    @@ -0,0 +1,6 @@
    +# Reviewing changes on iPhone
    +
    +Open a workspace and choose Changes.
    +Swipe between files to review the full patch.
    +Pinch to resize code.
    +Long-press a line to copy it.
    """

    private static let modifiedSwiftDiff = """
    @@ -8,7 +8,7 @@ final class SessionStore {
     private var sessions: [Session] = []
    -private var activeSession: Session?
    +private var selectedSession: Session?
     func currentSession() -> Session? {
    -    activeSession
    +    selectedSession
     }
    @@ -32,5 +32,5 @@ extension SessionStore {
     func refreshInterval() -> Duration {
    -    .seconds(30)
    +    .seconds(15)
     }
    @@ -48,6 +48,7 @@ extension SessionStore {
     func open(
         _ session: Session,
    +    animated: Bool = true,
    +    timeout: Duration = .seconds(10),
         focus: Bool
     ) {
         selectedSession = session
    """

    private static let deletedDiff = """
    @@ -1,5 +0,0 @@
    -import Foundation
    -
    -struct LegacySession {
    -    let identifier: UUID
    -}
    """

    private static let renamedDiff = """
    @@ -1,5 +1,5 @@
    -struct ProjectSession {
    -    let projectName: String
    +struct WorkspaceSession {
    +    let workspaceName: String
         let startedAt: Date
     }
    """

    private static let untrackedDiff = """
    @@ -0,0 +1,5 @@
    +import SwiftUI
    +
    +struct Scratchpad: View {
    +    var body: some View { Text("Scratch") }
    +}
    """

    private static let truncatedDiff = """
    @@ -1,3 +1,8 @@
     enum GeneratedSchema {
    +    static let field0001 = "value"
    +    static let field0002 = "value"
    +    static let field0003 = "value"
    +    static let field0004 = "value"
    +    static let field0005 = "value"
     }
    """
}
#endif
