// swift-tools-version: 6.0
import PackageDescription

// Linux has no CryptoKit, SQLite3 or Darwin module: CmuxLinuxCompat supplies
// the SQLite3 module, the `Darwin.`-qualified libc calls, SHA256 and
// String(localized:). Apple builds never see this dependency.
#if os(Linux)
let packageDependencies: [Package.Dependency] = [
    .package(path: "../../Shared/CmuxLinuxCompat"),
]
let targetDependencies: [Target.Dependency] = [
    .product(name: "CmuxLinuxSQLite3", package: "CmuxLinuxCompat"),
    .product(name: "CmuxLinuxCompat", package: "CmuxLinuxCompat"),
]
#else
let packageDependencies: [Package.Dependency] = []
let targetDependencies: [Target.Dependency] = []
#endif

let package = Package(
    name: "CMUXAgentLaunch",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CMUXAgentLaunch",
            targets: ["CMUXAgentLaunch"]
        ),
    ],
    dependencies: packageDependencies,
    targets: [
        .target(
            name: "CMUXAgentLaunch",
            dependencies: targetDependencies
        ),
        .testTarget(
            name: "CMUXAgentLaunchTests",
            dependencies: ["CMUXAgentLaunch"]
        ),
    ]
)
