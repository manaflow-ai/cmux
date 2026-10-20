// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CmuxDiffComments",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "CmuxDiffComments",
            targets: ["CmuxDiffComments"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxDiffComments",
            path: "Sources/CmuxDiffComments"
        ),
    ]
)
