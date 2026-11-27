// swift-tools-version: 6.0
import PackageDescription

// Linux lacks Apple-only APIs this package uses: CmuxLinuxCompat supplies
// the SQLite3 module and stand-ins (os Logger, `Darwin.`-qualified libc, String(localized:)).
// Apple builds never see this dependency.
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
    name: "CmuxAgentJournal",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxAgentJournal",
            targets: ["CmuxAgentJournal"]
        ),
    ],
    dependencies: packageDependencies,
    targets: [
        .target(
            name: "CmuxAgentJournal",
            dependencies: targetDependencies,
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxAgentJournalTests",
            dependencies: targetDependencies + ["CmuxAgentJournal"]
        ),
    ]
)
