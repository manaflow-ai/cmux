// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmuxAgentJournal",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxAgentJournal",
            targets: ["CmuxAgentJournal"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxAgentJournal",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxAgentJournalTests",
            dependencies: ["CmuxAgentJournal"]
        ),
    ]
)
