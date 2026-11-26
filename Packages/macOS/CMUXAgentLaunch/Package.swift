// swift-tools-version: 6.0
import PackageDescription

// Linux has no CryptoKit, SQLite3 or Darwin module: swift-crypto's Crypto
// has CryptoKit's API, and CmuxLinuxCompat supplies SQLite3 and the
// `Darwin.`-qualified libc calls and String(localized:). Apple builds never see these dependencies.
#if os(Linux)
let packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-crypto.git", "3.12.0"..<"5.0.0"),
    .package(path: "../../Shared/CmuxLinuxCompat"),
]
let targetDependencies: [Target.Dependency] = [
    .product(name: "Crypto", package: "swift-crypto"),
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
