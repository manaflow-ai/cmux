// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "cmux",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "cmux", targets: ["cmux"])
    ],
    dependencies: [
        .package(path: "Packages/CMUXAgentLaunch"),
        .package(path: "Packages/CMUXAgentVault"),
        .package(path: "Packages/CMUXNodeOptions"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "cmux",
            dependencies: ["CMUXAgentLaunch", "CMUXAgentVault", "CMUXNodeOptions", "SwiftTerm"],
            path: "Sources"
        )
    ]
)
