// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmuxCloudMachines",
    platforms: [.macOS(.v14)],
    products: [.library(name: "CmuxCloudMachines", targets: ["CmuxCloudMachines"])],
    targets: [
        .target(name: "CmuxCloudMachines"),
        .testTarget(name: "CmuxCloudMachinesTests", dependencies: ["CmuxCloudMachines"])
    ]
)
