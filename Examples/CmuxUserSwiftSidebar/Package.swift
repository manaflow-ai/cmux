// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmuxUserSwiftSidebarExample",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CompactUnreadSidebar", targets: ["CompactUnreadSidebar"]),
    ],
    dependencies: [
        .package(path: "../../Packages/CmuxExtensionKit"),
    ],
    targets: [
        .executableTarget(
            name: "CompactUnreadSidebar",
            dependencies: ["CmuxExtensionKit"],
            path: ".",
            exclude: ["README.md"],
            sources: ["CompactUnreadSidebar.swift"]
        ),
    ]
)
