// swift-tools-version: 6.0

import PackageDescription

// Brand marks for the coding agents, harnesses and model providers cmux supports.
// The catalog is generated from design/agent-icons by scripts/agent-icons/generate.py;
// the macOS app (CmuxNext) and the iOS app draw the same marks through it.
let package = Package(
    name: "CmuxAgentBrands",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CmuxAgentBrands", targets: ["CmuxAgentBrands"]),
    ],
    targets: [
        .target(
            name: "CmuxAgentBrands",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxAgentBrandsTests",
            dependencies: ["CmuxAgentBrands"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
