// swift-tools-version: 6.0

import PackageDescription

// Linux lacks Apple-only APIs this package uses: CmuxLinuxCompat supplies
// stand-ins (os Logger, `Darwin.`-qualified libc, String(localized:)).
// Apple builds never see this dependency.
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
    name: "CmuxMobileDiagnostics",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMobileDiagnostics",
            targets: ["CmuxMobileDiagnostics"]
        ),
    ],
    dependencies: packageDependencies,
    targets: [
        .target(
            name: "CmuxMobileDiagnostics",
            dependencies: targetDependencies,
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxMobileDiagnosticsTests",
            dependencies: targetDependencies + ["CmuxMobileDiagnostics"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
