// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StubAgentSidebarExtension",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "StubAgentSidebarExtension",
            targets: ["StubAgentSidebarExtension"]
        ),
    ],
    dependencies: [
        .package(path: "../../Packages/macOS/CmuxExtensionKit"),
    ],
    targets: [
        .target(
            name: "StubAgentSidebarExtension",
            dependencies: [
                .product(name: "CmuxExtensionKit", package: "CmuxExtensionKit"),
            ],
            resources: [
                .process("Resources"),
            ]
        ),
    ]
)
