// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CMUXVNC",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CMUXVNC",
            targets: ["CMUXVNC"]
        ),
    ],
    targets: [
        .target(name: "CMUXVNC"),
        .testTarget(
            name: "CMUXVNCTests",
            dependencies: ["CMUXVNC"]
        ),
    ]
)
