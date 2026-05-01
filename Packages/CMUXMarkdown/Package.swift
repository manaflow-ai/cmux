// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CMUXMarkdown",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "CMUXMarkdown", targets: ["CMUXMarkdown"]),
        .executable(name: "cmux-markdown-benchmark", targets: ["CMUXMarkdownBenchmark"])
    ],
    targets: [
        .target(name: "CMUXMarkdown"),
        .executableTarget(
            name: "CMUXMarkdownBenchmark",
            dependencies: ["CMUXMarkdown"]
        ),
        .testTarget(
            name: "CMUXMarkdownTests",
            dependencies: ["CMUXMarkdown"]
        )
    ]
)
