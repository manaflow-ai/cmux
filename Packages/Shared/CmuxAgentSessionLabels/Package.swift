// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmuxAgentSessionLabels",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "CmuxAgentSessionLabels", targets: ["CmuxAgentSessionLabels"])],
    targets: [
        .target(name: "CmuxAgentSessionLabels"),
        .testTarget(
            name: "CmuxAgentSessionLabelsTests",
            dependencies: ["CmuxAgentSessionLabels"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
