// swift-tools-version: 6.0
import PackageDescription

// Linux lacks String(localized:): CmuxLinuxCompat supplies a Bundle-backed
// stand-in. Apple builds never see this dependency.
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
    name: "CmuxCloudResizeCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CmuxCloudResizeCore", targets: ["CmuxCloudResizeCore"])
    ],
    dependencies: packageDependencies,
    targets: [
        .target(
            name: "CmuxCloudResizeCore",
            dependencies: targetDependencies,
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CmuxCloudResizeCoreTests",
            dependencies: ["CmuxCloudResizeCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
