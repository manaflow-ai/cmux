// swift-tools-version: 6.2

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
    dependencies: [
        // blockingCall for the fixture reads.
        .package(path: "../CmuxThreading"),
    ],
    targets: [
        .target(
            name: "CmuxAgentQuestion",
            dependencies: [.product(name: "CmuxThreading", package: "CmuxThreading")],
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

// BEGIN apply-stability-settings.py: generated from scripts/cmux-next/stability-settings.json; do not edit.
// p10 stability settings per target (plans/cmux-next/chrome-parity/p10-stability.md C.5): add a row to
// stability-settings.json and run the lander instead of editing this block or a target's settings.
let stabilitySettingGroups: [(targets: [String], settings: [SwiftSetting])] = [
    (
        targets: [
            "CmuxAgentQuestion",
            "CmuxAgentQuestionTests",
        ],
        settings: [
            .strictMemorySafety(),
        ]
    ),
]
for group in stabilitySettingGroups {
    for target in package.targets where group.targets.contains(target.name) {
        target.swiftSettings = (target.swiftSettings ?? []) + group.settings
    }
}
// END apply-stability-settings.py
