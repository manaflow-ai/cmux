// swift-tools-version: 6.0
import PackageDescription

// Linux has no CryptoKit: CmuxLinuxCompat supplies SHA256. Apple builds never
// see this dependency.
#if os(Linux)
let packageDependencies: [Package.Dependency] = [
    .package(path: "../../Shared/CmuxLinuxCompat"),
]
let targetDependencies: [Target.Dependency] = [
    .product(name: "CmuxLinuxCompat", package: "CmuxLinuxCompat"),
]
#else
let packageDependencies: [Package.Dependency] = []
let targetDependencies: [Target.Dependency] = []
#endif

let package = Package(
    name: "CmuxTerminalSharing",
    platforms: [.macOS(.v14)],
    products: [.library(name: "CmuxTerminalSharing", targets: ["CmuxTerminalSharing"])],
    dependencies: packageDependencies + [.package(path: "../../Shared/CmuxTerminalSizing")],
    targets: [
        .target(name: "CmuxTerminalSharing", dependencies: targetDependencies + ["CmuxTerminalSizing"]),
        .testTarget(name: "CmuxTerminalSharingTests", dependencies: ["CmuxTerminalSharing", "CmuxTerminalSizing"]),
    ],
    swiftLanguageModes: [.v6]
)
