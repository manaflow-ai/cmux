// swift-tools-version: 6.0

import PackageDescription

// `CmuxAgentSessionLabels` owns the cmux-authored display name of an agent
// session. Agent sessions arrive from each agent's own files, and none of those
// records carries a name cmux may write, so the label is the cmux-owned side of
// that pairing. The package is Foundation-only, because both the CLI and the
// macOS app write the same document and it has to be testable without the app.
let package = Package(
    name: "CmuxAgentSessionLabels",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "CmuxAgentSessionLabels", targets: ["CmuxAgentSessionLabels"])],
    targets: [
        .target(
            name: "CmuxAgentSessionLabels",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxAgentSessionLabelsTests",
            dependencies: ["CmuxAgentSessionLabels"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
