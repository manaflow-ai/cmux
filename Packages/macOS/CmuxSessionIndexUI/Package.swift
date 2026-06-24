// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxSessionIndexUI",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxSessionIndexUI",
            targets: ["CmuxSessionIndexUI"]
        ),
    ],
    dependencies: [
        // The session-index domain value types (e.g. SessionAgent, SessionEntry,
        // SessionTranscriptRole/DisplayRow, SessionTranscriptLoader) these views render
        // and load through. The leaf views take already-resolved presentation primitives
        // so they stay free of the app-side presentation extensions.
        .package(path: "../CmuxSessionIndex"),
        // RipgrepFileScanner, injected into SessionTranscriptLoader by the transcript
        // preview. CmuxSessionIndex already depends on CmuxFoundation; the transcript
        // view names the scanner type directly, so the UI target depends on it too.
        .package(path: "../CmuxFoundation"),
    ],
    targets: [
        .target(
            name: "CmuxSessionIndexUI",
            dependencies: [
                .product(name: "CmuxSessionIndex", package: "CmuxSessionIndex"),
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxSessionIndexUITests",
            dependencies: [
                "CmuxSessionIndexUI",
                .product(name: "CmuxSessionIndex", package: "CmuxSessionIndex"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
