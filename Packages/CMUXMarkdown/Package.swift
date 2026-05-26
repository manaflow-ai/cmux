// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CMUXMarkdown",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "CMUXMarkdown",
            targets: ["CMUXMarkdown"]
        ),
        .executable(
            name: "CMUXMarkdownBenchmark",
            targets: ["CMUXMarkdownBenchmark"]
        ),
        .executable(
            name: "CMUXMarkdownSnapshot",
            targets: ["CMUXMarkdownSnapshot"]
        ),
    ],
    targets: [
        .target(name: "CMUXMarkdown"),
        .executableTarget(
            name: "CMUXMarkdownBenchmark",
            dependencies: ["CMUXMarkdown"]
        ),
        .executableTarget(
            name: "CMUXMarkdownSnapshot",
            dependencies: ["CMUXMarkdown"]
        ),
        .testTarget(
            name: "CMUXMarkdownTests",
            dependencies: ["CMUXMarkdown"]
        ),
    ]
)
