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
        .package(path: "Packages/CMUXSocketPathDomain"),
        .package(path: "Packages/CMUXAgentVault"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "cmux",
            dependencies: ["CMUXSocketPathDomain", "CMUXAgentVault", "SwiftTerm"],
            path: "Sources"
        )
    ]
)
