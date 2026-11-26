// swift-tools-version: 6.0

import PackageDescription

// One harness-neutral model for a question an agent asks a person
// (plans/cmux-next/agent-questions.md): Claude Code's AskUserQuestion, a
// Codex user-input request, a generic ACP interactive permission and a
// Chief question in Home all map to `AgentQuestion`, and every answer is
// encoded back into the asking harness's own shape. Foundation only, so the
// Mac app, the iOS app and tests share it. The JSON fixtures under
// Sources/CmuxAgentQuestion/Fixtures are plain data: the Swift tests, the UI
// Gallery and the web gallery read the same files.
let package = Package(
    name: "CmuxAgentQuestion",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CmuxAgentQuestion", targets: ["CmuxAgentQuestion"]),
    ],
    targets: [
        .target(
            name: "CmuxAgentQuestion",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxAgentQuestionTests",
            dependencies: ["CmuxAgentQuestion"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
