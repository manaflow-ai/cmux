// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GhosttyTabs",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "GhosttyTabs", targets: ["GhosttyTabs"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "GhosttyTabs",
            dependencies: ["SwiftTerm"],
            path: "Sources"
        )
    ]
)
